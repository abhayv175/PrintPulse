import os
import json
import sqlite3
import logging
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Any, Iterator
from collections.abc import MutableMapping
from contextlib import contextmanager

logger = logging.getLogger("printpulse.db")

BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_DB_PATH = os.path.join(BASE_DIR, "printpulse.db")
UPLOAD_DIR = os.path.join(BASE_DIR, "uploads")


def get_db_path() -> str:
    return os.getenv("SQLITE_DB_PATH", DEFAULT_DB_PATH)


@contextmanager
def get_db_connection() -> Iterator[sqlite3.Connection]:
    """
    Context manager that yields an active SQLite connection configured with:
    - WAL journal mode for non-blocking concurrent reads and crash protection
    - 5000ms busy timeout to prevent database lock contention
    - Normal synchronous mode for high performance
    - Row factory for named access
    - Automatic transaction commit/rollback
    - Guaranteed connection closure upon exit
    """
    conn = sqlite3.connect(get_db_path(), timeout=10.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("PRAGMA busy_timeout = 5000;")
    conn.execute("PRAGMA synchronous = NORMAL;")
    try:
        with conn:
            yield conn
    finally:
        conn.close()


def init_db() -> None:
    """Initializes the database schema for PrintPulse orders and files."""
    db_path = get_db_path()
    os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
    with get_db_connection() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS orders (
                order_id TEXT PRIMARY KEY,
                vendor_id TEXT NOT NULL,
                status TEXT NOT NULL,
                total_amount REAL DEFAULT 0.0,
                total_pages INTEGER DEFAULT 0,
                copies INTEGER DEFAULT 1,
                color_mode TEXT DEFAULT 'bw',
                files_json TEXT,
                documents_json TEXT,
                payload_json TEXT NOT NULL,
                created_at TIMESTAMP NOT NULL,
                expires_at TIMESTAMP NOT NULL
            );
            """
        )
        conn.execute("CREATE INDEX IF NOT EXISTS idx_orders_vendor_created ON orders (vendor_id, created_at DESC);")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_orders_expires_at ON orders (expires_at);")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_orders_status ON orders (status);")
    logger.info(f"SQLite initialized at {db_path}")


def _parse_datetime(val: Any) -> datetime:
    if isinstance(val, datetime):
        return val
    if isinstance(val, str):
        try:
            return datetime.fromisoformat(val)
        except ValueError:
            for fmt in (
                "%Y-%m-%d %H:%M:%S.%f",
                "%Y-%m-%d %H:%M:%S",
                "%Y-%m-%dT%H:%M:%SZ",
                "%Y-%m-%d",
            ):
                try:
                    return datetime.strptime(val, fmt)
                except ValueError:
                    continue
    return datetime.now()


def _resolve_file_path(fpath: str) -> str:
    """Resolves relative and absolute upload paths to their absolute location on disk."""
    if not fpath:
        return ""
    if os.path.isabs(fpath):
        return fpath
    clean_rel = fpath.lstrip("/")
    if clean_rel.startswith("uploads/"):
        clean_rel = clean_rel[len("uploads/") :]
    return os.path.join(UPLOAD_DIR, clean_rel)


def _delete_files_from_disk(files: List[str]) -> List[str]:
    """Deletes list of filepaths from disk safely."""
    deleted = []
    for fpath in files:
        if not fpath:
            continue
        try:
            target = _resolve_file_path(fpath)
            if target and os.path.isfile(target):
                os.remove(target)
                deleted.append(target)
        except (FileNotFoundError, OSError) as e:
            logger.debug(f"File delete note for {fpath}: {e}")
    return deleted


def _extract_all_files(order_dict: Dict[str, Any]) -> List[str]:
    """Extracts all physical file paths from both order['files'] and order['documents']."""
    files: List[str] = []
    for f in (order_dict.get("files") or []):
        if f and isinstance(f, str) and f not in files:
            files.append(f)
    for doc in (order_dict.get("documents") or []):
        if isinstance(doc, dict):
            for key in ("staged_path", "staged_file", "file_path", "filepath"):
                val = doc.get(key)
                if val and isinstance(val, str) and val not in files:
                    files.append(val)
    return files


def prune_vendor_documents(vendor_id: str, max_allowed: int = 5) -> List[str]:
    """
    Enforces the 'Max 5 documents/orders per vendor' rule.
    Any orders past the top 5 newest have their PDF/image files removed from disk
    and their database rows deleted.
    """
    if not vendor_id:
        return []

    clean_vendor = str(vendor_id).strip()
    pruned_order_ids: List[str] = []

    with get_db_connection() as conn:
        cursor = conn.execute(
            """
            SELECT order_id, files_json, payload_json
            FROM orders
            WHERE vendor_id = ?
            ORDER BY created_at DESC, rowid DESC
            LIMIT -1 OFFSET ?;
            """,
            (clean_vendor, max_allowed),
        )
        excess_rows = cursor.fetchall()
        for row in excess_rows:
            oid = row["order_id"]
            pruned_order_ids.append(oid)
            files = []
            if row["payload_json"]:
                try:
                    data = json.loads(row["payload_json"])
                    files = _extract_all_files(data)
                except Exception:
                    pass

            if not files and row["files_json"]:
                try:
                    files = json.loads(row["files_json"])
                except Exception:
                    pass

            # 1. Delete physical files
            _delete_files_from_disk(files)

            # 2. Clean any staged files matching {order_id}_* or {order_id}.* in vendor upload directory
            vendor_dir = os.path.join(UPLOAD_DIR, clean_vendor)
            if os.path.isdir(vendor_dir):
                for fname in os.listdir(vendor_dir):
                    if fname.startswith(f"{oid}_") or fname.startswith(f"{oid}."):
                        try:
                            os.remove(os.path.join(vendor_dir, fname))
                        except (FileNotFoundError, OSError):
                            pass

            # 3. Delete database row
            conn.execute("DELETE FROM orders WHERE order_id = ?;", (oid,))

        if excess_rows:
            logger.info(
                f"Pruned {len(excess_rows)} excess order(s) for vendor {clean_vendor} to enforce {max_allowed}-doc cap: {pruned_order_ids}"
            )

    return pruned_order_ids


def save_order(order_dict: Dict[str, Any], max_vendor_docs: int = 5) -> None:
    """
    Persists an order dictionary to SQLite and enforces the 5-document cap for that vendor.
    """
    if not order_dict or not order_dict.get("order_id"):
        return

    order_id = str(order_dict["order_id"]).strip()
    existing = get_order(order_id)
    if existing:
        merged = dict(existing)
        merged.update(order_dict)
    else:
        merged = dict(order_dict)

    vendor_id = str(merged.get("vendor_id", "default")).strip()
    status = str(merged.get("status", "awaiting_payment")).strip()
    total_amount = float(merged.get("total_amount", 0.0) or 0.0)
    total_pages = int(merged.get("total_pages", merged.get("pages", 0)) or 0)
    copies = int(merged.get("copies", 1) or 1)
    color_mode = str(merged.get("color_mode", "bw")).strip()

    created_at = _parse_datetime(merged.get("created_at"))
    expires_at = merged.get("expires_at")
    if expires_at:
        expires_at = _parse_datetime(expires_at)
    else:
        expires_at = created_at + timedelta(hours=24)

    files = merged.get("files", [])
    documents = merged.get("documents", [])

    files_json = json.dumps(files, default=str)
    documents_json = json.dumps(documents, default=str)
    payload_json = json.dumps(merged, default=str)

    with get_db_connection() as conn:
        conn.execute(
            """
            INSERT INTO orders (
                order_id, vendor_id, status, total_amount, total_pages, copies,
                color_mode, files_json, documents_json, payload_json,
                created_at, expires_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(order_id) DO UPDATE SET
                status = excluded.status,
                total_amount = excluded.total_amount,
                total_pages = excluded.total_pages,
                copies = excluded.copies,
                color_mode = excluded.color_mode,
                files_json = excluded.files_json,
                documents_json = excluded.documents_json,
                payload_json = excluded.payload_json,
                expires_at = excluded.expires_at;
            """,
            (
                order_id,
                vendor_id,
                status,
                total_amount,
                total_pages,
                copies,
                color_mode,
                files_json,
                documents_json,
                payload_json,
                created_at.isoformat(),
                expires_at.isoformat(),
            ),
        )

    # Enforce maximum 5 documents/orders for this vendor
    prune_vendor_documents(vendor_id, max_allowed=max_vendor_docs)


def get_order(order_id: str) -> Optional[Dict[str, Any]]:
    """Retrieves an order dictionary by ID."""
    if not order_id:
        return None
    with get_db_connection() as conn:
        cursor = conn.execute("SELECT payload_json FROM orders WHERE order_id = ?;", (order_id.strip(),))
        row = cursor.fetchone()
        if row and row["payload_json"]:
            try:
                return json.loads(row["payload_json"])
            except Exception:
                pass
    return None


def delete_order(order_id: str) -> Optional[Dict[str, Any]]:
    """Deletes an order from SQLite and removes all associated files from disk."""
    if not order_id:
        return None
    clean_id = str(order_id).strip()
    order = get_order(clean_id)

    if order:
        files = _extract_all_files(order)
        _delete_files_from_disk(files)

        vendor_id = order.get("vendor_id")
        if vendor_id:
            vendor_dir = os.path.join(UPLOAD_DIR, str(vendor_id).strip())
            if os.path.isdir(vendor_dir):
                for fname in os.listdir(vendor_dir):
                    if fname.startswith(f"{clean_id}_") or fname.startswith(f"{clean_id}."):
                        try:
                            os.remove(os.path.join(vendor_dir, fname))
                        except (FileNotFoundError, OSError):
                            pass

    with get_db_connection() as conn:
        conn.execute("DELETE FROM orders WHERE order_id = ?;", (clean_id,))

    return order


def get_all_orders() -> Dict[str, Dict[str, Any]]:
    """Returns a dictionary of all active orders mapped by order_id."""
    res: Dict[str, Dict[str, Any]] = {}
    with get_db_connection() as conn:
        cursor = conn.execute("SELECT order_id, payload_json FROM orders ORDER BY created_at DESC;")
        for row in cursor.fetchall():
            try:
                res[row["order_id"]] = json.loads(row["payload_json"])
            except Exception:
                continue
    return res


def get_orders_by_vendor(vendor_id: str) -> List[Dict[str, Any]]:
    """Returns all active orders for a vendor, newest first."""
    if not vendor_id:
        return []
    orders: List[Dict[str, Any]] = []
    with get_db_connection() as conn:
        cursor = conn.execute(
            "SELECT payload_json FROM orders WHERE vendor_id = ? ORDER BY created_at DESC;",
            (str(vendor_id).strip(),),
        )
        for row in cursor.fetchall():
            try:
                orders.append(json.loads(row["payload_json"]))
            except Exception:
                continue
    return orders


def cleanup_expired_orders(ttl_hours: int = 24) -> int:
    """
    Periodic cleanup task:
    1. Removes all orders where expires_at <= now.
    2. Deletes all physical PDF files from disk.
    3. Scans for orphan files in uploads/ not tracked in SQLite.
    Returns the count of purged orders.
    """
    now = datetime.now()
    cutoff_iso = now.isoformat()
    purged_count = 0

    with get_db_connection() as conn:
        cursor = conn.execute(
            "SELECT order_id, files_json, payload_json FROM orders WHERE expires_at <= ?;",
            (cutoff_iso,),
        )
        expired_rows = cursor.fetchall()
        for row in expired_rows:
            oid = row["order_id"]
            files = []
            if row["payload_json"]:
                try:
                    data = json.loads(row["payload_json"])
                    files = _extract_all_files(data)
                except Exception:
                    pass
            if not files and row["files_json"]:
                try:
                    files = json.loads(row["files_json"])
                except Exception:
                    pass

            _delete_files_from_disk(files)
            conn.execute("DELETE FROM orders WHERE order_id = ?;", (oid,))
            purged_count += 1

        if purged_count > 0:
            logger.info(f"Cleanup: Purged {purged_count} expired orders and their files from disk.")

    # Orphan file cleanup: remove any abandoned files in uploads/ older than 2 hours that are not in DB
    try:
        _cleanup_orphan_files_on_disk(max_age_hours=2)
    except Exception as e:
        logger.debug(f"Orphan file cleanup note: {e}")

    return purged_count


def _cleanup_orphan_files_on_disk(max_age_hours: int = 2) -> int:
    """Scans uploads/ and unlinks any orphaned files not referenced in SQLite."""
    if not os.path.isdir(UPLOAD_DIR):
        return 0

    orphans_removed = 0
    cutoff = datetime.now() - timedelta(hours=max_age_hours)

    with get_db_connection() as conn:
        cursor = conn.execute("SELECT order_id FROM orders;")
        active_order_ids = {row["order_id"] for row in cursor.fetchall()}

    for root, dirs, files in os.walk(UPLOAD_DIR):
        for fname in files:
            if fname.startswith("."):
                continue
            fpath = os.path.join(root, fname)
            try:
                mtime = datetime.fromtimestamp(os.path.getmtime(fpath))
                if mtime < cutoff:
                    # Check if file starts with an order ID prefix e.g. ORD-XXXXXX_
                    if fname.startswith("ORD-"):
                        oid_prefix = fname.split("_")[0]
                        if oid_prefix not in active_order_ids:
                            os.remove(fpath)
                            orphans_removed += 1
            except (FileNotFoundError, OSError):
                continue

    return orphans_removed


class SQLiteOrderStore(MutableMapping):
    """
    Drop-in dictionary-compatible mapping backed directly by SQLite.
    Allows existing code using ORDERS[id], ORDERS.get(id), id in ORDERS, ORDERS.items(), etc.
    to execute high-speed atomic SQLite queries with zero code breakage.
    """

    def __getitem__(self, key: str) -> Dict[str, Any]:
        item = get_order(str(key))
        if item is None:
            raise KeyError(key)
        return item

    def __setitem__(self, key: str, value: Dict[str, Any]) -> None:
        if isinstance(value, dict):
            value["order_id"] = str(key)
            save_order(value)

    def __delitem__(self, key: str) -> None:
        deleted = delete_order(str(key))
        if deleted is None:
            raise KeyError(key)

    def __iter__(self) -> Iterator[str]:
        with get_db_connection() as conn:
            cursor = conn.execute("SELECT order_id FROM orders ORDER BY created_at DESC;")
            for row in cursor.fetchall():
                yield row["order_id"]

    def __len__(self) -> int:
        with get_db_connection() as conn:
            cursor = conn.execute("SELECT COUNT(*) AS cnt FROM orders;")
            row = cursor.fetchone()
            return int(row["cnt"]) if row else 0

    def __contains__(self, key: Any) -> bool:
        if not key:
            return False
        with get_db_connection() as conn:
            cursor = conn.execute("SELECT 1 FROM orders WHERE order_id = ? LIMIT 1;", (str(key).strip(),))
            return cursor.fetchone() is not None

    def get(self, key: str, default: Any = None) -> Any:
        item = get_order(str(key))
        return item if item is not None else default

    def pop(self, key: str, default: Any = None) -> Any:
        item = delete_order(str(key))
        return item if item is not None else default

    def items(self):
        return get_all_orders().items()

    def values(self):
        return get_all_orders().values()

    def keys(self):
        return list(self.__iter__())


# Singleton instance that acts as the in-memory/SQLite ORDERS dictionary
ORDERS: SQLiteOrderStore = SQLiteOrderStore()


def save_orders_to_disk() -> None:
    """Compatibility no-op: Orders are written directly to SQLite upon assignment."""
    pass
