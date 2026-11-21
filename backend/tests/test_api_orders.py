import os
import unittest
import tempfile
from app.core import db
from app.core.db import ORDERS, save_orders_to_disk


class TestOrdersIntegration(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.temp_dir.name, "test_integration.db")
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

    def test_orders_store_operations_without_json_file(self):
        """Verify that all dictionary operations used in routes work seamlessly on SQLite."""
        # 1. Insertion
        ORDERS["ORD-TEST-1"] = {
            "order_id": "ORD-TEST-1",
            "vendor_id": "v_test",
            "status": "awaiting_payment",
            "total_amount": 50.0,
            "total_pages": 10,
            "copies": 1,
            "color_mode": "bw",
            "files": [],
        }

        # 2. Key check and get
        self.assertIn("ORD-TEST-1", ORDERS)
        order = ORDERS.get("ORD-TEST-1")
        self.assertIsNotNone(order)
        self.assertEqual(order["status"], "awaiting_payment")

        # 3. Mutation and persistence
        order["status"] = "paid"
        ORDERS["ORD-TEST-1"] = order
        save_orders_to_disk() # Verify no-op does not crash

        updated = ORDERS.get("ORD-TEST-1")
        self.assertEqual(updated["status"], "paid")

        # 4. Iteration and length
        self.assertEqual(len(ORDERS), 1)
        keys = list(ORDERS.keys())
        self.assertEqual(keys, ["ORD-TEST-1"])

        # 5. Pop / Deletion
        removed = ORDERS.pop("ORD-TEST-1", None)
        self.assertIsNotNone(removed)
        self.assertNotIn("ORD-TEST-1", ORDERS)
        self.assertEqual(len(ORDERS), 0)


if __name__ == "__main__":
    unittest.main()
