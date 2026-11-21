import os
import time
import unittest
import tempfile
import threading
from datetime import datetime, timedelta
from app.core import db


class TestSQLiteEdgeCases(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.temp_dir.name, "edge_case.db")
        self.upload_dir = os.path.join(self.temp_dir.name, "uploads")
        os.makedirs(self.upload_dir, exist_ok=True)

        self.orig_db_path = db.get_db_path()
        self.orig_upload_dir = db.UPLOAD_DIR

        os.environ["SQLITE_DB_PATH"] = self.db_path
        db.UPLOAD_DIR = self.upload_dir
        db.init_db()

    def tearDown(self):
        os.environ["SQLITE_DB_PATH"] = self.orig_db_path
        db.UPLOAD_DIR = self.orig_upload_dir
        self.temp_dir.cleanup()

    def test_idempotency_same_order_updates(self):
        """Updating an existing order multiple times must NOT count against the 5-cap."""
        order_id = "ORD-STATUS-FLOW"
        # 1. Created
        db.save_order({"order_id": order_id, "vendor_id": "v_idem", "status": "awaiting_payment"})
        self.assertEqual(len(db.get_orders_by_vendor("v_idem")), 1)

        # 2. Claimed
        db.save_order({"order_id": order_id, "vendor_id": "v_idem", "status": "claimed", "utr": "123456"})
        self.assertEqual(len(db.get_orders_by_vendor("v_idem")), 1)

        # 3. Verified / Paid
        db.save_order({"order_id": order_id, "vendor_id": "v_idem", "status": "paid"})
        self.assertEqual(len(db.get_orders_by_vendor("v_idem")), 1)

        order = db.get_order(order_id)
        self.assertEqual(order["status"], "paid")
        self.assertEqual(order.get("utr"), "123456")

    def test_multi_tenant_isolation(self):
        """Pruning Vendor A's excess orders must NEVER touch Vendor B's orders or files."""
        dir_a = os.path.join(self.upload_dir, "vendor_A")
        dir_b = os.path.join(self.upload_dir, "vendor_B")
        os.makedirs(dir_a, exist_ok=True)
        os.makedirs(dir_b, exist_ok=True)

        # Vendor B uploads 3 orders
        files_b = []
        for i in range(1, 4):
            fp = os.path.join(dir_b, f"doc_b_{i}.pdf")
            with open(fp, "w") as f:
                f.write(f"vendor B content {i}")
            files_b.append(fp)
            db.save_order({
                "order_id": f"ORD-B-{i}",
                "vendor_id": "vendor_B",
                "files": [fp],
                "created_at": (datetime.now() + timedelta(minutes=i)).isoformat(),
            }, max_vendor_docs=5)

        # Vendor A uploads 8 orders (should prune to 5)
        files_a = []
        for i in range(1, 9):
            fp = os.path.join(dir_a, f"doc_a_{i}.pdf")
            with open(fp, "w") as f:
                f.write(f"vendor A content {i}")
            files_a.append(fp)
            db.save_order({
                "order_id": f"ORD-A-{i}",
                "vendor_id": "vendor_A",
                "files": [fp],
                "created_at": (datetime.now() + timedelta(minutes=i + 10)).isoformat(),
            }, max_vendor_docs=5)

        # Check Vendor A
        orders_a = db.get_orders_by_vendor("vendor_A")
        self.assertEqual(len(orders_a), 5)
        self.assertFalse(os.path.exists(files_a[0])) # oldest 3 deleted
        self.assertFalse(os.path.exists(files_a[1]))
        self.assertFalse(os.path.exists(files_a[2]))
        self.assertTrue(os.path.exists(files_a[7])) # newest remain

        # Check Vendor B (100% untouched)
        orders_b = db.get_orders_by_vendor("vendor_B")
        self.assertEqual(len(orders_b), 3)
        for fp in files_b:
            self.assertTrue(os.path.exists(fp))

    def test_multi_file_and_documents_extraction(self):
        """When an order has multiple files across 'files' and 'documents', all must be deleted."""
        v_dir = os.path.join(self.upload_dir, "multi_v")
        os.makedirs(v_dir, exist_ok=True)

        f1 = os.path.join(v_dir, "doc1.pdf")
        f2 = os.path.join(v_dir, "doc2.pdf")
        f3 = os.path.join(v_dir, "doc3.png")

        for f in (f1, f2, f3):
            with open(f, "w") as fp:
                fp.write("dummy")

        order = {
            "order_id": "ORD-MULTI-FILES",
            "vendor_id": "multi_v",
            "files": [f1],
            "documents": [
                {"staged_path": f2, "filename": "doc2.pdf"},
                {"staged_file": f3, "filename": "doc3.png"},
            ],
        }
        db.save_order(order)
        db.delete_order("ORD-MULTI-FILES")

        self.assertFalse(os.path.exists(f1))
        self.assertFalse(os.path.exists(f2))
        self.assertFalse(os.path.exists(f3))

    def test_missing_files_graceful(self):
        """Deleting an order whose files were already removed from disk must not raise errors."""
        order = {
            "order_id": "ORD-GHOST",
            "vendor_id": "v_ghost",
            "files": [os.path.join(self.upload_dir, "non_existent_file.pdf")],
        }
        db.save_order(order)
        # Should execute cleanly without FileNotFoundError
        deleted = db.delete_order("ORD-GHOST")
        self.assertIsNotNone(deleted)

    def test_sql_injection_safety(self):
        """Ensure SQL injection attempts in IDs and payloads are safely handled by prepared statements."""
        malicious_vendor = "shopkeeper'; DROP TABLE orders; --"
        malicious_order_id = "ORD-INJECT' OR '1'='1"

        order = {
            "order_id": malicious_order_id,
            "vendor_id": malicious_vendor,
            "total_amount": 100.0,
            "notes": "Testing SQL injection safety",
        }
        db.save_order(order)

        # Verify table was NOT dropped and order is retrievable
        fetched = db.get_order(malicious_order_id)
        self.assertIsNotNone(fetched)
        self.assertEqual(fetched["vendor_id"], malicious_vendor)

        vendor_orders = db.get_orders_by_vendor(malicious_vendor)
        self.assertEqual(len(vendor_orders), 1)

    def test_concurrent_multithreaded_writes(self):
        """Verify WAL mode handles concurrent write/read threads without database locking exceptions."""
        errors = []

        def worker(thread_id: int):
            try:
                for i in range(15):
                    oid = f"ORD-TH-{thread_id}-{i}"
                    db.save_order({
                        "order_id": oid,
                        "vendor_id": f"vendor_th_{thread_id}",
                        "status": "awaiting_payment",
                        "total_amount": float(i * 10),
                    })
                    fetched = db.get_order(oid)
                    if not fetched or fetched["order_id"] != oid:
                        errors.append(f"Mismatch in thread {thread_id} for {oid}")
            except Exception as e:
                errors.append(f"Thread {thread_id} crashed with: {e}")

        threads = [threading.Thread(target=worker, args=(t,)) for t in range(6)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(errors, [], f"Concurrent write errors encountered: {errors}")

    def test_orphan_file_cleanup(self):
        """Unreferenced files in uploads/ older than 2 hours should be pruned."""
        v_dir = os.path.join(self.upload_dir, "v_orphan")
        os.makedirs(v_dir, exist_ok=True)

        orphan_file = os.path.join(v_dir, "ORD-ABANDONED_temp.pdf")
        with open(orphan_file, "w") as f:
            f.write("orphan content")

        # Fake old mtime (3 hours ago)
        old_mtime = time.time() - (3 * 3600)
        os.utime(orphan_file, (old_mtime, old_mtime))

        cleaned = db._cleanup_orphan_files_on_disk(max_age_hours=2)
        self.assertEqual(cleaned, 1)
        self.assertFalse(os.path.exists(orphan_file))


if __name__ == "__main__":
    unittest.main()
