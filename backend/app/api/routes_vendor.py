import hashlib
import os
import re
from collections import defaultdict
from typing import Dict, List, Optional
from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect, status
from pydantic import BaseModel

router = APIRouter()

DEFAULT_VENDOR_UPI_ID = os.getenv("DEFAULT_VENDOR_UPI_ID", "shop@okaxis")
DEFAULT_VENDOR_NAME = os.getenv("DEFAULT_VENDOR_NAME", "PrintPulse Kiosk")
DEFAULT_BW_PRICE = float(os.getenv("DEFAULT_BW_PRICE", "2.0"))
DEFAULT_COLOR_PRICE = float(os.getenv("DEFAULT_COLOR_PRICE", "10.0"))

# In-memory vendor registry: {vendor_id: {"vendor_id", "email", "upi_id", "vendor_name", "bw_price", "color_price"}}
VENDORS: Dict[str, dict] = {}

EMAIL_REGEX = re.compile(r"^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$")
UPI_REGEX = re.compile(r"^[a-zA-Z0-9._-]{2,256}@[a-zA-Z0-9.-]{2,64}$")


class RegisterVendorRequest(BaseModel):
    email: str
    upi_id: Optional[str] = None
    vendor_name: Optional[str] = None


class UpdateVendorUpiRequest(BaseModel):
    upi_id: str
    vendor_name: Optional[str] = None


class UpdateVendorPricingRequest(BaseModel):
    bw_price: float
    color_price: float


class VendorOnboardingRequest(BaseModel):
    shop_name: str
    bw_price: float
    color_price: float
    upi_id: str
    vendor_name: Optional[str] = None


def get_vendor_profile(vendor_id: str) -> dict:
    """
    Returns an existing vendor record or provisions default UPI settlement & pricing details.
    """
    clean_id = os.path.basename(vendor_id.strip()) or "kiosk"
    existing = VENDORS.get(clean_id)
    if existing:
        if not existing.get("upi_id"):
            existing["upi_id"] = DEFAULT_VENDOR_UPI_ID
        if not existing.get("vendor_name"):
            existing["vendor_name"] = DEFAULT_VENDOR_NAME
        if "bw_price" not in existing:
            existing["bw_price"] = DEFAULT_BW_PRICE
        if "color_price" not in existing:
            existing["color_price"] = DEFAULT_COLOR_PRICE
        if "onboarded" not in existing:
            existing["onboarded"] = False
        if "onboarding_completed" not in existing:
            existing["onboarding_completed"] = False
        return existing

    profile = {
        "vendor_id": clean_id,
        "upi_id": DEFAULT_VENDOR_UPI_ID,
        "vendor_name": DEFAULT_VENDOR_NAME,
        "bw_price": DEFAULT_BW_PRICE,
        "color_price": DEFAULT_COLOR_PRICE,
        "onboarded": False,
        "onboarding_completed": False,
    }
    VENDORS[clean_id] = profile
    return profile


def generate_vendor_id_from_email(email: str) -> str:
    """
    Derive a URL- and filesystem-safe vendor ID from an email address prefix.
    Strips @domain, lowercases, replaces dots/special chars with '_', and
    falls back to a deterministic hash prefix only if the sanitized slug is empty.
    """
    cleaned = email.strip().lower()
    raw_handle = cleaned.split("@")[0].strip()
    sanitized = re.sub(r"[^a-z0-9_-]+", "_", raw_handle).strip("_")
    if sanitized:
        return sanitized
    digest = hashlib.sha256(cleaned.encode("utf-8")).hexdigest()[:8]
    return f"vendor_{digest}"


generate_vendor_id = generate_vendor_id_from_email


class ConnectionManager:
    """Manages active WebSocket connections per vendor."""

    def __init__(self):
        self.active_connections: Dict[str, List[WebSocket]] = defaultdict(list)

    async def connect(self, vendor_id: str, websocket: WebSocket):
        await websocket.accept()
        self.active_connections[vendor_id].append(websocket)

    def disconnect(self, vendor_id: str, websocket: WebSocket):
        if vendor_id in self.active_connections:
            if websocket in self.active_connections[vendor_id]:
                self.active_connections[vendor_id].remove(websocket)
            if not self.active_connections[vendor_id]:
                del self.active_connections[vendor_id]

    async def broadcast_to_vendor(self, vendor_id: str, message: dict):
        if vendor_id in self.active_connections:
            for connection in list(self.active_connections[vendor_id]):
                try:
                    await connection.send_json(message)
                except Exception:
                    self.disconnect(vendor_id, connection)


manager = ConnectionManager()


async def broadcast_job(vendor_id: str, job_data: dict):
    """Async helper to push incoming order payloads to the vendor's active WebSocket."""
    await manager.broadcast_to_vendor(vendor_id, job_data)


@router.post("/register")
async def register_vendor(payload: RegisterVendorRequest):
    email = payload.email.strip()
    if not EMAIL_REGEX.match(email):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid email format. Please provide a valid email address.",
        )

    vendor_id = generate_vendor_id(email)
    existing = VENDORS.get(vendor_id, {})
    upi_id = (payload.upi_id or "").strip() or existing.get("upi_id") or DEFAULT_VENDOR_UPI_ID
    vendor_name = (payload.vendor_name or "").strip() or existing.get("vendor_name") or DEFAULT_VENDOR_NAME
    VENDORS[vendor_id] = {
        **existing,
        "vendor_id": vendor_id,
        "email": email.lower(),
        "upi_id": upi_id,
        "vendor_name": vendor_name,
    }

    return {
        "vendor_id": vendor_id,
        "upi_id": upi_id,
        "vendor_name": vendor_name,
        "portal_url": f"/shop/{vendor_id}",
    }


@router.get("/{vendor_id}/profile")
async def get_vendor(vendor_id: str):
    return get_vendor_profile(vendor_id)


@router.patch("/{vendor_id}/upi")
@router.post("/{vendor_id}/upi")
async def update_vendor_upi(vendor_id: str, payload: UpdateVendorUpiRequest):
    upi_clean = payload.upi_id.strip()
    if not UPI_REGEX.match(upi_clean):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid UPI VPA format (expected handle@bank, e.g. shop@okaxis).",
        )
    profile = get_vendor_profile(vendor_id)
    profile["upi_id"] = upi_clean
    if payload.vendor_name and payload.vendor_name.strip():
        profile["vendor_name"] = payload.vendor_name.strip()
    return profile


@router.patch("/{vendor_id}/onboard")
@router.post("/{vendor_id}/onboard")
async def onboard_vendor(vendor_id: str, payload: VendorOnboardingRequest):
    """
    Saves shop name, print rates, and verified UPI ID during initial vendor onboarding.
    Updates the in-memory profile and flags onboarding as completed.
    """
    clean_id = os.path.basename(vendor_id.strip())
    if not clean_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid vendor ID.",
        )

    clean_shop = payload.shop_name.strip()
    if not clean_shop:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Shop name cannot be empty.",
        )

    if payload.bw_price <= 0 or payload.color_price <= 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Print prices must be positive numbers greater than 0.",
        )

    upi_clean = payload.upi_id.strip()
    if not UPI_REGEX.match(upi_clean):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid UPI VPA format (expected handle@bank, e.g. shop@okaxis).",
        )

    profile = get_vendor_profile(clean_id)
    profile["shop_name"] = clean_shop
    profile["vendor_name"] = (payload.vendor_name or "").strip() or clean_shop
    profile["name"] = profile["vendor_name"]
    profile["bw_price"] = round(float(payload.bw_price), 2)
    profile["color_price"] = round(float(payload.color_price), 2)
    profile["upi_id"] = upi_clean
    profile["onboarded"] = True
    profile["onboarding_completed"] = True

    return {
        "success": True,
        "vendor_id": clean_id,
        "shop_name": profile["shop_name"],
        "vendor_name": profile["vendor_name"],
        "bw_price": profile["bw_price"],
        "color_price": profile["color_price"],
        "upi_id": profile["upi_id"],
        "onboarded": True,
        "onboarding_completed": True,
    }


@router.get("/{vendor_id}/pricing")
async def get_vendor_pricing(vendor_id: str):
    """Returns the vendor's active per-page print rates for B&W and Color."""
    profile = get_vendor_profile(vendor_id)
    return {
        "vendor_id": profile["vendor_id"],
        "bw_price": float(profile.get("bw_price", DEFAULT_BW_PRICE)),
        "color_price": float(profile.get("color_price", DEFAULT_COLOR_PRICE)),
    }


@router.post("/{vendor_id}/pricing")
async def update_vendor_pricing(
    vendor_id: str,
    payload: UpdateVendorPricingRequest,
):
    """Updates the shopkeeper's per-page printing rates."""
    if payload.bw_price <= 0 or payload.color_price <= 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Print rates must be positive numbers greater than 0.",
        )

    profile = get_vendor_profile(vendor_id)
    profile["bw_price"] = round(float(payload.bw_price), 2)
    profile["color_price"] = round(float(payload.color_price), 2)

    return {
        "vendor_id": profile["vendor_id"],
        "bw_price": profile["bw_price"],
        "color_price": profile["color_price"],
        "message": "Print rates updated successfully.",
    }


@router.get("/{vendor_id}/stats")
async def get_vendor_stats(vendor_id: str):
    """
    Returns daily session revenue and page volume breakdown
    (B&W vs. Color) calculated strictly from completed orders.
    """
    from app.api.routes_upload import ORDERS

    clean_id = os.path.basename(vendor_id.strip())
    session_revenue = 0.0
    bw_pages_printed = 0
    color_pages_printed = 0
    completed_orders = 0

    for oid, order in ORDERS.items():
        if order.get("vendor_id") == clean_id and order.get("status") == "completed":
            completed_orders += 1
            session_revenue += float(order.get("total_amount", 0.0))
            docs = order.get("documents", [])
            if docs:
                for doc in docs:
                    p = int(doc.get("pages", 1)) * int(doc.get("copies", 1))
                    if doc.get("is_color"):
                        color_pages_printed += p
                    else:
                        bw_pages_printed += p
            else:
                p = int(order.get("total_pages") or order.get("pages") or 1)
                if order.get("color_mode") == "color":
                    color_pages_printed += p
                else:
                    bw_pages_printed += p

    return {
        "vendor_id": clean_id,
        "session_revenue": round(session_revenue, 2),
        "bw_pages_printed": bw_pages_printed,
        "color_pages_printed": color_pages_printed,
        "completed_orders": completed_orders,
    }


@router.get("/{vendor_id}/history")
async def get_vendor_history_endpoint(vendor_id: str):
    """
    Returns completed print orders for a given vendor, sorted newest-first with
    UPI payer name and payment timestamps for the vendor app History tab.
    """
    from app.api.routes_orders import get_vendor_order_history
    return await get_vendor_order_history(vendor_id)


@router.delete("/{vendor_id}/history")
async def delete_vendor_history(vendor_id: str):
    """
    Deletes all completed and rejected orders for that vendor_id from the database
    (leaving any active/pending queue orders untouched), and cleans up any cached disk files.
    Returns 200 OK.
    """
    from app.api.routes_upload import ORDERS, delete_order_files, save_orders_to_disk

    clean_vendor_id = os.path.basename(vendor_id.strip())
    orders_to_delete = []

    for oid, order in list(ORDERS.items()):
        if order.get("vendor_id") == clean_vendor_id:
            st = (order.get("status") or "").lower()
            pst = (order.get("payment_status") or "").upper()
            # Delete only settled history: completed, rejected, or cancelled
            if st in ("completed", "rejected", "cancelled") or pst in ("COMPLETED", "REJECTED"):
                orders_to_delete.append(oid)

    deleted_count = 0
    for oid in orders_to_delete:
        order = ORDERS.pop(oid, None)
        if order:
            try:
                delete_order_files(oid, order)
            except Exception:
                pass
            deleted_count += 1

    if deleted_count > 0:
        save_orders_to_disk()

    # Also permanently clean up from Prisma MongoDB if running
    try:
        from prisma import Prisma
        db = Prisma()
        if not db.is_connected():
            await db.connect()
        await db.printjob.delete_many(
            where={
                "vendor_id": clean_vendor_id,
                "status": {"in": ["completed", "rejected", "cancelled"]},
            }
        )
    except Exception:
        pass

    return {
        "success": True,
        "message": f"Deleted {deleted_count} completed/rejected order history record(s) for vendor '{clean_vendor_id}'.",
        "deleted_count": deleted_count,
        "vendor_id": clean_vendor_id,
    }


@router.websocket("/ws/vendor/{vendor_id}")
async def websocket_vendor(websocket: WebSocket, vendor_id: str):
    await manager.connect(vendor_id, websocket)
    try:
        while True:
            # Keep the socket open; handle ping / client messages
            await websocket.receive_text()
    except (WebSocketDisconnect, Exception):
        manager.disconnect(vendor_id, websocket)
