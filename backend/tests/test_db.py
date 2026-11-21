import os
import unittest
import tempfile
from datetime import datetime, timedelta
from app.core import db


class TestSQLiteDB(unittest.TestCase):
    def setUp(self):
        # Use isolated temporary database for tests
        self.temp_dir = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.temp_dir.name, "test_printpulse.db")
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

    def test_save_and_get_order(self):
        order_data = {
            "order_id": "ORD-101",
            "vendor_id": "v1",
            "status": "awaiting_payment",
            "total_amount": 25.50,
            "total_pages": 5,
            "copies": 1,
            "files": [],
        }
        db.save_order(order_data)
        fetched = db.get_order("ORD-101")
        self.assertIsNotNone(fetched)
        self.assertEqual(fetched["order_id"], "ORD-101")
        self.assertEqual(fetched["total_amount"], 25.50)

    def test_five_document_cap_per_vendor(self):
        # Create dummy PDF files on disk for each order
        vendor_dir = os.path.join(self.upload_dir, "vendor_cap")
        os.makedirs(vendor_dir, exist_ok=True)

        file_paths = []
        for i in range(1, 8):
            fpath = os.path.join(vendor_dir, f"test_order_{i}.pdf")
            with open(fpath, "w") as f:
                f.write(f"PDF content for order {i}")
            file_paths.append(fpath)

            order = {
                "order_id": f"ORD-{i:03d}",
                "vendor_id": "vendor_cap",
                "status": "awaiting_payment",
                "created_at": (datetime.utcnow() + timedelta(minutes=i)).isoformat(),
                "files": [fpath],
            }
            db.save_order(order, max_vendor_docs=5)

        # There should only be 5 orders in the database for vendor_cap
        vendor_orders = db.get_orders_by_vendor("vendor_cap")
        self.assertEqual(len(vendor_orders), 5)

        # The 2 oldest orders (ORD-001 and ORD-002) should have been pruned from DB
        self.assertIsNone(db.get_order("ORD-001"))
        self.assertIsNone(db.get_order("ORD-002"))
        self.assertIsNotNone(db.get_order("ORD-007"))

        # The pruned files should have been removed from disk!
        self.assertFalse(os.path.exists(file_paths[0])) # order 1
        self.assertFalse(os.path.exists(file_paths[1])) # order 2
        # The 5 newest files must remain on disk
        self.assertTrue(os.path.exists(file_paths[6])) # order 7

    def test_cleanup_expired_orders_24h(self):
        # Create an expired order and file
        fpath = os.path.join(self.upload_dir, "expired.pdf")
        with open(fpath, "w") as f:
            f.write("expired pdf")

        expired_order = {
            "order_id": "ORD-EXPIRED",
            "vendor_id": "v_expired",
            "created_at": (datetime.utcnow() - timedelta(hours=25)).isoformat(),
            "expires_at": (datetime.utcnow() - timedelta(hours=1)).isoformat(),
            "files": [fpath],
        }
        db.save_order(expired_order)

        # Active order
        fpath_active = os.path.join(self.upload_dir, "active.pdf")
        with open(fpath_active, "w") as f:
            f.write("active pdf")

        active_order = {
            "order_id": "ORD-ACTIVE",
            "vendor_id": "v_expired",
            "created_at": datetime.utcnow().isoformat(),
            "expires_at": (datetime.utcnow() + timedelta(hours=23)).isoformat(),
            "files": [fpath_active],
        }
        db.save_order(active_order)

        purged = db.cleanup_expired_orders(ttl_hours=24)
        self.assertEqual(purged, 1)

        # Expired order removed from DB and disk
        self.assertIsNone(db.get_order("ORD-EXPIRED"))
        self.assertFalse(os.path.exists(fpath))

        # Active order remains
        self.assertIsNotNone(db.get_order("ORD-ACTIVE"))
        self.assertTrue(os.path.exists(fpath_active))

    def test_sqlite_order_store_mapping(self):
        store = db.ORDERS
        store["ORD-MAP-1"] = {"vendor_id": "v_map", "total_amount": 10.0}

        self.assertIn("ORD-MAP-1", store)
        self.assertEqual(store["ORD-MAP-1"]["vendor_id"], "v_map")
        self.assertEqual(store.get("ORD-MAP-1")["total_amount"], 10.0)
        self.assertEqual(len(store), 1)

        popped = store.pop("ORD-MAP-1")
        self.assertIsNotNone(popped)
        self.assertNotIn("ORD-MAP-1", store)
        self.assertEqual(len(store), 0)


if __name__ == "__main__":
    unittest.main()
