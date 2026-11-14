import os
import uuid
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Body, HTTPException, WebSocket, WebSocketDisconnect, status
from pydantic import BaseModel
from app.core.pricing import build_upi_uri, compute_order_amount
from app.api.routes_upload import ORDERS, delete_order_files, save_orders_to_disk
from app.api.routes_vendor import ConnectionManager, get_vendor_profile, manager

router = APIRouter()

# Tracks active customer checkout WebSockets listening on /ws/orders/{order_id}
order_ws_manager = ConnectionManager()

DEFAULT_HOST_URL = (
    os.getenv("API_BASE_URL")
    or os.getenv("SHOP_BASE_URL", "http://192.168.1.41:8000")
).rstrip("/")


class CreateOrderRequest(BaseModel):
    vendor_id: str
    pages: int = 1
    copies: int = 1
    color_mode: str = "bw"
    page_range: Optional[str] = "all"
    orientation: Optional[str] = "portrait"
    is_color: Optional[bool] = None
    order_id: Optional[str] = None
    vendor_vpa: Optional[str] = None
    vendor_name: Optional[str] = None


class VerifyPaymentRequest(BaseModel):
    transaction_ref: Optional[str] = None
    utr: Optional[str] = None
    verified_by: str = "webhook"


class UpdateOrderStatusRequest(BaseModel):
    status: str


def _build_paid_event_payload(order: dict) -> dict:
    """Formats the canonical order_paid WebSocket event payload."""
    order_id = order["order_id"]
    vendor_id = order["vendor_id"]
    amount = round(float(order.get("total_amount", 0.0)), 2)
    docs = order.get("documents", [])
    if docs:
        pages = sum(int(d.get("pages", 1)) * int(d.get("copies", 1)) for d in docs)
        copies = sum(int(d.get("copies", 1)) for d in docs)
    else:
        pages = int(order.get("total_pages") or order.get("pages") or 1)
        copies = int(order.get("copies") or 1)
    color_mode = order.get("color_mode") or "bw"
    paid_at = order.get("paid_at") or datetime.now().isoformat(timespec="seconds")

    return {
        "event": "order_paid",
        "type": "status_update",
        "order_id": order_id,
        "vendor_id": vendor_id,
        "status": "paid",
        "order": {
            "order_id": order_id,
            "vendor_id": vendor_id,
            "amount": amount,
            "total_amount": amount,
            "pages": pages,
            "total_pages": pages,
            "copies": copies,
            "color_mode": color_mode,
            "page_range": order.get("page_range", "all"),
            "orientation": order.get("orientation", "portrait"),
            "download_url": order.get(
                "download_url",
                f"{DEFAULT_HOST_URL}/api/documents/{order_id}/download",
            ),
            "print_ready_url": order.get(
                "print_ready_url",
                f"{DEFAULT_HOST_URL}/api/documents/{order_id}/print-ready",
            ),
            "status": "paid",
            "paid_at": paid_at,
            "printing_started_at": order.get("printing_started_at"),
            "completed_at": order.get("completed_at"),
            "transaction_ref": order.get("transaction_ref"),
            "documents": order.get("documents", []),
        },
    }


def _build_status_event_payload(order: dict, new_status: Optional[str] = None) -> dict:
    """Builds standard order status update event for WebSocket broadcast and API responses."""
    status_val = (new_status or order.get("status", "pending_payment")).lower()
    paid_payload = _build_paid_event_payload(order)
    order_data = dict(paid_payload["order"])
    order_data["status"] = status_val
    order_data["printing_started_at"] = order.get("printing_started_at")
    order_data["completed_at"] = order.get("completed_at")

    event_name = "order_paid" if status_val == "paid" else "order_status_update"

    return {
        "type": "status_update",
        "event": event_name,
        "order_id": order["order_id"],
        "vendor_id": order["vendor_id"],
        "status": status_val,
        "order": order_data,
    }


@router.post("/create")
async def create_order(payload: CreateOrderRequest):
    """
    Creates (or enriches an already-staged) print order with server-computed INR
    pricing and an NPCI-compliant dynamic UPI intent URI.
    """
    clean_vendor_id = os.path.basename(payload.vendor_id.strip())
    if not clean_vendor_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid vendor_id.",
        )

    vendor = get_vendor_profile(clean_vendor_id)
    vendor_vpa = (payload.vendor_vpa or "").strip() or vendor["upi_id"]
    vendor_name = (payload.vendor_name or "").strip() or vendor["vendor_name"]

    # Reuse staged batch-upload order when order_id is provided and exists
    if payload.order_id and payload.order_id.strip() in ORDERS:
        existing = ORDERS[payload.order_id.strip()]
        order_id = existing["order_id"]
        total_amount = round(float(existing["total_amount"]), 2)
        transaction_ref = existing.get("transaction_ref") or f"TXN_{order_id}"
        upi_uri = build_upi_uri(
            vendor_vpa=vendor_vpa,
            vendor_name=vendor_name,
            total_amount=total_amount,
            order_id=order_id,
            transaction_ref=transaction_ref,
        )
        existing["transaction_ref"] = transaction_ref
        existing["upi_uri"] = upi_uri
        if payload.page_range:
            existing["page_range"] = payload.page_range.strip() or "all"
        if payload.orientation:
            existing["orientation"] = payload.orientation.strip().lower() or "portrait"
        return {
            "order_id": order_id,
            "vendor_id": existing["vendor_id"],
            "vendor_vpa": vendor_vpa,
            "vendor_name": vendor_name,
            "total_amount": total_amount,
            "total_pages": existing.get("total_pages", existing.get("pages", 1)),
            "orientation": existing.get("orientation", "portrait"),
            "transaction_ref": transaction_ref,
            "upi_uri": upi_uri,
            "upi_string": upi_uri,
            "status": existing.get("status", "pending_payment"),
        }

    is_color_mode = (
        payload.is_color
        if payload.is_color is not None
        else payload.color_mode.strip().lower() == "color"
    )
    try:
        pricing = compute_order_amount(
            pages=payload.pages,
            copies=payload.copies,
            is_color=is_color_mode,
            bw_rate=float(vendor.get("bw_price", 2.0)),
            color_rate=float(vendor.get("color_price", 10.0)),
        )
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(exc),
        )

    order_id = (payload.order_id or "").strip() or f"ord_{uuid.uuid4().hex[:5]}"
    transaction_ref = f"TXN_{order_id}"
    color_mode = "color" if is_color_mode else "bw"
    order_orientation = (payload.orientation or "portrait").strip().lower()
    if order_orientation not in ("portrait", "landscape"):
        order_orientation = "portrait"
    upi_uri = build_upi_uri(
        vendor_vpa=vendor_vpa,
        vendor_name=vendor_name,
        total_amount=pricing.total_amount,
        order_id=order_id,
        transaction_ref=transaction_ref,
    )

    ORDERS[order_id] = {
        "order_id": order_id,
        "vendor_id": clean_vendor_id,
        "files": [],
        "documents": [],
        "total_amount": pricing.total_amount,
        "pages": pricing.pages,
        "total_pages": pricing.pages * pricing.copies,
        "copies": pricing.copies,
        "color_mode": color_mode,
        "page_range": (payload.page_range or "all").strip() or "all",
        "orientation": order_orientation,
        "transaction_ref": transaction_ref,
        "upi_uri": upi_uri,
        "created_at": datetime.now(),
        "status": "pending_payment",
    }

    await manager.broadcast_to_vendor(
        clean_vendor_id,
        {
            "event": "NEW_PRINT_JOB",
            "order_id": order_id,
            "vendor_id": clean_vendor_id,
            "timestamp": datetime.now().strftime("%I:%M %p"),
            "status": "pending_payment",
            "total_amount": pricing.total_amount,
            "pages": pricing.pages,
            "copies": pricing.copies,
            "color_mode": color_mode,
            "page_range": (payload.page_range or "all").strip() or "all",
            "orientation": order_orientation,
            "total_pages": pricing.pages * pricing.copies,
            "documents": [],
        },
    )

    return {
        "order_id": order_id,
        "vendor_id": clean_vendor_id,
        "vendor_vpa": vendor_vpa,
        "vendor_name": vendor_name,
        "total_amount": pricing.total_amount,
        "total_pages": pricing.pages * pricing.copies,
        "transaction_ref": transaction_ref,
        "upi_uri": upi_uri,
        "upi_string": upi_uri,
        "status": "pending_payment",
    }


@router.get("/{order_id}/status")
async def get_order_status(order_id: str):
    """Returns current payment and print status with order metadata for polling fallback."""
    order = ORDERS.get(order_id)
    if not order:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Order '{order_id}' not found.",
        )

    status_payload = _build_status_event_payload(order)
    return {
        "order_id": order["order_id"],
        "vendor_id": order["vendor_id"],
        "status": order.get("status", "pending_payment"),
        "total_amount": round(float(order.get("total_amount", 0.0)), 2),
        "total_pages": order.get("total_pages", order.get("pages", 1)),
        "copies": order.get("copies", 1),
        "color_mode": order.get("color_mode", "bw"),
        "orientation": order.get("orientation", "portrait"),
        "paid_at": order.get("paid_at"),
        "printing_started_at": order.get("printing_started_at"),
        "completed_at": order.get("completed_at"),
        "transaction_ref": order.get("transaction_ref"),
        "upi_uri": order.get("upi_uri"),
        "order": status_payload["order"],
    }


@router.get("/{order_id}")
async def get_order_details(order_id: str):
    """Returns complete order object for tracking lifecycle."""
    order = ORDERS.get(order_id)
    if not order:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Order '{order_id}' not found.",
        )
    status_payload = _build_status_event_payload(order)
    return status_payload["order"]


@router.post("/{order_id}/status")
async def update_order_status(
    order_id: str,
    payload: UpdateOrderStatusRequest,
):
    """
    Updates the lifecycle status of an order ('paid', 'printing', 'completed', 'cancelled')
    and broadcasts the update in real-time to both customer web tracker and vendor terminal.
    """
    order = ORDERS.get(order_id)
    if not order:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Order '{order_id}' not found.",
        )

    new_status = payload.status.strip().lower()
    valid_statuses = {"pending_payment", "paid", "printing", "completed", "cancelled"}
    if new_status not in valid_statuses:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid status '{new_status}'. Allowed: {sorted(list(valid_statuses))}",
        )

    order["status"] = new_status
    now_iso = datetime.now().isoformat(timespec="seconds")
    if new_status == "printing" and not order.get("printing_started_at"):
        order["printing_started_at"] = now_iso
    elif new_status == "completed" and not order.get("completed_at"):
        order["completed_at"] = now_iso

    # Instantly delete uploaded source files when an order completes or is cancelled
    if new_status in ("completed", "cancelled"):
        delete_order_files(order_id, order)

    save_orders_to_disk()

    status_payload = _build_status_event_payload(order, new_status)
    await order_ws_manager.broadcast_to_vendor(order_id, status_payload)
    await manager.broadcast_to_vendor(order["vendor_id"], status_payload)

    return {
        "success": True,
        "order_id": order_id,
        "status": new_status,
        "order": status_payload["order"],
    }


@router.get("/vendor/{vendor_id}")
async def get_vendor_active_orders(vendor_id: str):
    """
    Returns active (pending_payment and paid) orders for a given vendor.
    Allows Flutter vendor app to immediately populate its queue on launch/reconnect.
    """
    clean_vendor_id = os.path.basename(vendor_id.strip())
    active_orders = []
    for oid, order in ORDERS.items():
        if (
            order.get("vendor_id") == clean_vendor_id
            and order.get("status") != "cancelled"
        ):
            docs = order.get("documents", [])
            if docs:
                p_pages = sum(
                    int(d.get("pages", 1)) * int(d.get("copies", 1))
                    for d in docs
                )
                p_copies = sum(int(d.get("copies", 1)) for d in docs)
            else:
                p_pages = int(order.get("total_pages") or order.get("pages") or 1)
                p_copies = int(order.get("copies") or 1)

            created_raw = order.get("created_at")
            if isinstance(created_raw, datetime):
                created_str = created_raw.isoformat()
            else:
                created_str = str(created_raw or "")

            active_orders.append(
                {
                    "order_id": order.get("order_id", oid),
                    "vendor_id": clean_vendor_id,
                    "total_amount": round(
                        float(order.get("total_amount", 0.0)), 2
                    ),
                    "total_pages": p_pages,
                    "pages": p_pages,
                    "copies": p_copies,
                    "color_mode": order.get("color_mode", "bw"),
                    "page_range": order.get("page_range", "all"),
                    "orientation": order.get("orientation", "portrait"),
                    "download_url": order.get(
                        "download_url",
                        f"{DEFAULT_HOST_URL}/api/documents/{oid}/download",
                    ),
                    "print_ready_url": order.get(
                        "print_ready_url",
                        f"{DEFAULT_HOST_URL}/api/documents/{oid}/print-ready",
                    ),
                    "status": order.get("status", "pending_payment"),
                    "paid_at": order.get("paid_at"),
                    "transaction_ref": order.get("transaction_ref"),
                    "created_at": created_str,
                    "documents": order.get("documents", []),
                }
            )
    return {"orders": active_orders}


@router.post("/{order_id}/verify-payment")
async def verify_order_payment(
    order_id: str,
    payload: Optional[VerifyPaymentRequest] = Body(default=None),
):
    """
    Confirms UPI settlement for an order (via webhook or shopkeeper approval)
    and broadcasts an immediate 'order_paid' WebSocket event to vendor and customer.
    """
    order = ORDERS.get(order_id)
    if not order:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Order '{order_id}' not found.",
        )

    if order.get("status") == "cancelled":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Order '{order_id}' was cancelled and cannot be marked paid.",
        )

    already_paid = order.get("status") == "paid"
    if not already_paid:
        paid_at = datetime.now().isoformat(timespec="seconds")
        order["status"] = "paid"
        order["paid_at"] = paid_at
        if payload:
            if payload.utr:
                order["utr"] = payload.utr.strip()
            if payload.transaction_ref:
                order["transaction_ref"] = payload.transaction_ref.strip()
            order["verified_by"] = payload.verified_by

        save_orders_to_disk()
        event_payload = _build_paid_event_payload(order)
        await manager.broadcast_to_vendor(order["vendor_id"], event_payload)
        await order_ws_manager.broadcast_to_vendor(order_id, event_payload)
    else:
        event_payload = _build_paid_event_payload(order)

    return {
        "status": "paid",
        "already_paid": already_paid,
        "order_id": order_id,
        "vendor_id": order["vendor_id"],
        "order": event_payload["order"],
    }


async def websocket_order_status(websocket: WebSocket, order_id: str):
    """WebSocket stream allowing customer web checkout to react immediately to payment & printing lifecycle."""
    await order_ws_manager.connect(order_id, websocket)
    try:
        order = ORDERS.get(order_id)
        if order and order.get("status") in ("paid", "printing", "completed", "cancelled"):
            await websocket.send_json(_build_status_event_payload(order))

        while True:
            await websocket.receive_text()
    except (WebSocketDisconnect, Exception):
        order_ws_manager.disconnect(order_id, websocket)
