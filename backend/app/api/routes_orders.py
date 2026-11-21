import os
import random
import urllib.parse
import uuid
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Body, HTTPException, Query, WebSocket, WebSocketDisconnect, status
from pydantic import BaseModel
from app.core.network import get_base_url
from app.core.pricing import build_upi_uri, compute_order_amount
from app.core.fcm import trigger_fcm_notification
from app.api.routes_upload import ORDERS, delete_order_files, save_orders_to_disk
from app.api.routes_vendor import (
    ConnectionManager,
    get_vendor_profile,
    manager,
    DEFAULT_VENDOR_UPI_ID,
    DEFAULT_VENDOR_NAME,
)

router = APIRouter()


def _trigger_pusher(channel: str, event_name: str, data: dict):
    """Graceful Pusher broadcast fallback."""
    pusher_app_id = os.getenv("PUSHER_APP_ID")
    pusher_key = os.getenv("PUSHER_KEY")
    pusher_secret = os.getenv("PUSHER_SECRET")
    pusher_cluster = os.getenv("PUSHER_CLUSTER", "ap2")
    if pusher_app_id and pusher_key and pusher_secret:
        try:
            import pusher
            p = pusher.Pusher(
                app_id=pusher_app_id,
                key=pusher_key,
                secret=pusher_secret,
                cluster=pusher_cluster,
                ssl=True,
            )
            p.trigger(channel, event_name, data)
        except Exception:
            pass


# Tracks active customer checkout WebSockets listening on /ws/orders/{order_id}
order_ws_manager = ConnectionManager()

DEFAULT_HOST_URL = get_base_url()


class CreateOrderRequest(BaseModel):
    vendor_id: str
    pages: int = 1
    page_count: Optional[int] = None
    copies: int = 1
    color_mode: str = "bw"
    page_range: Optional[str] = "all"
    orientation: Optional[str] = "portrait"
    is_color: Optional[bool] = None
    order_id: Optional[str] = None
    vendor_vpa: Optional[str] = None
    vendor_name: Optional[str] = None
    payer_name: Optional[str] = None
    auto_delete_after_print: bool = False


class ClaimPaymentRequest(BaseModel):
    utr_number: Optional[str] = None
    payer_name: Optional[str] = None
    amount: Optional[float] = None


class VerifyPaymentRequest(BaseModel):
    approved: Optional[bool] = True
    transaction_ref: Optional[str] = None
    utr: Optional[str] = None
    utr_number: Optional[str] = None
    verified_by: str = "webhook"
    payer_name: Optional[str] = None
    payer_vpa: Optional[str] = None
    amount: Optional[float] = None


class UpdateOrderStatusRequest(BaseModel):
    status: str


def _build_paid_event_payload(order: dict) -> dict:
    """Formats the canonical order_paid / new_order WebSocket event payload."""
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
    auto_delete = bool(order.get("auto_delete_after_print", False))
    payment_method = order.get("payment_method") or "upi"
    token_code = order.get("token_code")
    payer_name = order.get("payer_name") or ("UPI Customer" if payment_method != "cash" else f"Cash Customer (#{token_code or 'Cash'})")

    return {
        "event": "new_order",
        "type": "new_order",
        "order_id": order_id,
        "vendor_id": vendor_id,
        "status": "paid",
        "payment_method": payment_method,
        "token_code": token_code,
        "payer_name": payer_name,
        "auto_delete_after_print": auto_delete,
        "order": {
            "order_id": order_id,
            "vendor_id": vendor_id,
            "payer_name": payer_name,
            "payment_method": payment_method,
            "token_code": token_code,
            "amount": amount,
            "total_amount": amount,
            "pages": pages,
            "total_pages": pages,
            "copies": copies,
            "color_mode": color_mode,
            "page_range": order.get("page_range", "all"),
            "orientation": order.get("orientation", "portrait"),
            "auto_delete_after_print": auto_delete,
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
        "payer_name": order_data.get("payer_name", "UPI Customer"),
        "auto_delete_after_print": paid_payload.get("auto_delete_after_print", False),
        "order": order_data,
    }


def recalculate_order_amount(order: dict) -> float:
    """
    Strictly re-calculates the expected sum of the exact documents tied to this order_id
    using the vendor profile rates or stored rate_per_page.
    """
    clean_vendor_id = os.path.basename(str(order.get("vendor_id", "")).strip())
    vendor = get_vendor_profile(clean_vendor_id)
    bw_price = float(vendor.get("bw_price", 2.0))
    color_price = float(vendor.get("color_price", 10.0))

    documents = order.get("documents") or []
    if documents and isinstance(documents, list):
        total = 0.0
        for doc in documents:
            if not isinstance(doc, dict):
                continue
            pages = int(doc.get("pages", 1) or 1)
            copies = int(doc.get("copies", 1) or 1)
            is_color = bool(doc.get("is_color", False))
            rate = float(doc.get("rate_per_page") or (color_price if is_color else bw_price))
            total += round(pages * copies * rate, 2)
        return round(total, 2)
    else:
        # Fallback for single-file orders created directly via /api/orders/create
        pages = int(order.get("pages", order.get("total_pages", 1)) or 1)
        copies = int(order.get("copies", 1) or 1)
        is_color = str(order.get("color_mode", "")).lower() == "color" or bool(order.get("is_color", False))
        rate = color_price if is_color else bw_price
        return round(pages * copies * rate, 2)


def validate_cart_and_amount(order: dict, submitted_amount: Optional[float] = None) -> float:
    """
    Strictly verifies that:
    1. The order has not been cancelled or marked cart_invalidated.
    2. The re-calculated sum of all exact documents currently tied to this order_id
       matches the server's locked total_amount.
    3. If a submitted payment amount is provided, it matches the server-calculated total.
    Raises HTTPException(400) if any discrepancy is detected.
    """
    if order.get("status") == "cancelled" or order.get("cart_invalidated"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Cart modified after payment initiation. Please restart checkout.",
        )

    expected_amount = recalculate_order_amount(order)
    current_total = round(float(order.get("total_amount", 0.0)), 2)

    # Check if order total differs from exact document sum
    if abs(current_total - expected_amount) > 0.01:
        order["cart_invalidated"] = True
        save_orders_to_disk()
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Cart modified after payment initiation. Please restart checkout.",
        )

    # Check if locked_amount from checkout initiation differs from recalculation
    locked_amount = order.get("locked_amount")
    if locked_amount is not None:
        if abs(float(locked_amount) - expected_amount) > 0.01:
            order["cart_invalidated"] = True
            save_orders_to_disk()
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Cart modified after payment initiation. Please restart checkout.",
            )

    # Check submitted payment amount if provided
    if submitted_amount is not None:
        sub_amt = round(float(submitted_amount), 2)
        if abs(sub_amt - expected_amount) > 0.01:
            order["cart_invalidated"] = True
            save_orders_to_disk()
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Cart modified after payment initiation. Please restart checkout.",
            )

    return expected_amount


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
        if payload.auto_delete_after_print is not None:
            existing["auto_delete_after_print"] = bool(payload.auto_delete_after_print)
        if payload.payer_name:
            existing["payer_name"] = payload.payer_name.strip()
        existing_status = existing.get("status", "awaiting_payment")
        if existing_status == "pending_payment":
            existing_status = "awaiting_payment"
            existing["status"] = existing_status
        existing["locked_amount"] = total_amount
        existing["cart_invalidated"] = False
        save_orders_to_disk()
        return {
            "order_id": order_id,
            "vendor_id": existing["vendor_id"],
            "vendor_vpa": vendor_vpa,
            "vendor_name": vendor_name,
            "payer_name": existing.get("payer_name") or "UPI Customer",
            "total_amount": total_amount,
            "total_pages": existing.get("total_pages", existing.get("pages", 1)),
            "orientation": existing.get("orientation", "portrait"),
            "auto_delete_after_print": bool(existing.get("auto_delete_after_print", False)),
            "transaction_ref": transaction_ref,
            "upi_uri": upi_uri,
            "upi_string": upi_uri,
            "status": existing_status,
        }

    is_color_mode = (
        payload.is_color
        if payload.is_color is not None
        else payload.color_mode.strip().lower() == "color"
    )
    effective_pages = payload.page_count if payload.page_count is not None else payload.pages
    try:
        pricing = compute_order_amount(
            pages=effective_pages,
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

    order_payer_name = (payload.payer_name or "").strip() or "UPI Customer"
    ORDERS[order_id] = {
        "order_id": order_id,
        "vendor_id": clean_vendor_id,
        "payer_name": order_payer_name,
        "files": [],
        "documents": [],
        "total_amount": pricing.total_amount,
        "pages": pricing.pages,
        "total_pages": pricing.pages * pricing.copies,
        "copies": pricing.copies,
        "color_mode": color_mode,
        "page_range": (payload.page_range or "all").strip() or "all",
        "orientation": order_orientation,
        "auto_delete_after_print": bool(payload.auto_delete_after_print),
        "transaction_ref": transaction_ref,
        "upi_uri": upi_uri,
        "created_at": datetime.now(),
        "status": "awaiting_payment",
        "locked_amount": pricing.total_amount,
        "cart_invalidated": False,
    }
    save_orders_to_disk()

    return {
        "order_id": order_id,
        "vendor_id": clean_vendor_id,
        "vendor_vpa": vendor_vpa,
        "vendor_name": vendor_name,
        "payer_name": order_payer_name,
        "total_amount": pricing.total_amount,
        "total_pages": pricing.pages * pricing.copies,
        "auto_delete_after_print": bool(payload.auto_delete_after_print),
        "transaction_ref": transaction_ref,
        "upi_uri": upi_uri,
        "upi_string": upi_uri,
        "status": "awaiting_payment",
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
        "payer_name": order.get("payer_name") or "UPI Customer",
        "status": order.get("status", "pending_payment"),
        "total_amount": round(float(order.get("total_amount", 0.0)), 2),
        "total_pages": order.get("total_pages", order.get("pages", 1)),
        "copies": order.get("copies", 1),
        "color_mode": order.get("color_mode", "bw"),
        "orientation": order.get("orientation", "portrait"),
        "auto_delete_after_print": bool(order.get("auto_delete_after_print", False)),
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
    valid_statuses = {
        "awaiting_payment",
        "pending_payment",
        "pending_cash",
        "paid",
        "printing",
        "completed",
        "cancelled",
    }
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
        if new_status == "completed":
            order["payment_status"] = "COMPLETED"

    save_orders_to_disk()

    status_payload = _build_status_event_payload(order, new_status)
    await order_ws_manager.broadcast_to_vendor(order_id, status_payload)
    await manager.broadcast_to_vendor(order["vendor_id"], status_payload)
    _trigger_pusher(f"vendor-{order['vendor_id']}", f"order_{new_status}", status_payload)
    _trigger_pusher(f"order-{order_id}", f"order_{new_status}", status_payload)

    # Ephemeral pass-through: immediately purge cancelled job; completed orders retain lightweight receipt metadata
    if new_status == "cancelled":
        ORDERS.pop(order_id, None)
        save_orders_to_disk()

    return {
        "success": True,
        "order_id": order_id,
        "status": new_status,
        "files_purged": new_status in ("completed", "cancelled"),
        "order": status_payload["order"],
    }


@router.post("/{order_id}/complete")
async def complete_order(order_id: str):
    """
    Direct endpoint to complete an order, purge local temporary file buffers from disk,
    broadcast completion, and evict the job from server memory (zero-database ephemeral pass-through).
    """
    order = ORDERS.get(order_id)
    if not order:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Order/Job '{order_id}' not found.",
        )

    validate_cart_and_amount(order)
    order["status"] = "completed"
    order["payment_status"] = "COMPLETED"
    order["completed_at"] = datetime.now().isoformat(timespec="seconds")
    delete_order_files(order_id, order)

    status_payload = _build_status_event_payload(order, "completed")
    await order_ws_manager.broadcast_to_vendor(order_id, status_payload)
    await manager.broadcast_to_vendor(order["vendor_id"], status_payload)
    _trigger_pusher(f"vendor-{order['vendor_id']}", "order_completed", status_payload)
    _trigger_pusher(f"order-{order_id}", "order_completed", status_payload)

    ORDERS.pop(order_id, None)
    save_orders_to_disk()

    return {
        "success": True,
        "order_id": order_id,
        "status": "completed",
        "payment_status": "COMPLETED",
        "purged": True,
        "order": status_payload["order"],
    }


def evict_expired_orders(ttl_seconds: int = 1800) -> int:
    """
    Automatically purges expired/stale orders older than ttl_seconds (default 30 mins)
    and permanently deletes temporary files from disk to enforce zero-cloud-storage.
    """
    now = datetime.now()
    expired_ids = []
    for oid, ord_data in list(ORDERS.items()):
        status_val = (ord_data.get("status") or "").lower()
        if status_val in ("awaiting_payment", "pending_payment", "cancelled"):
            created_raw = ord_data.get("created_at")
            if created_raw:
                try:
                    if isinstance(created_raw, str):
                        dt = datetime.fromisoformat(created_raw.replace("Z", "+00:00"))
                    else:
                        dt = created_raw
                    if dt.tzinfo is not None:
                        dt = dt.replace(tzinfo=None)
                    if (now - dt).total_seconds() > ttl_seconds:
                        expired_ids.append(oid)
                except Exception:
                    pass
    for oid in expired_ids:
        delete_order_files(oid, ORDERS.get(oid))
        ORDERS.pop(oid, None)
    if expired_ids:
        save_orders_to_disk()
    return len(expired_ids)


@router.post("/evict-expired")
@router.post("/cleanup")
async def trigger_eviction(ttl_seconds: int = 1800):
    """Triggers eviction of expired in-memory jobs and temporary file buffers."""
    evicted_count = evict_expired_orders(ttl_seconds)
    return {
        "success": True,
        "evicted_orders": evicted_count,
        "active_in_memory_orders": len(ORDERS),
    }


@router.post("/{order_id}/select-cash")
async def select_cash_order(order_id: str):
    """
    Triggered when customer selects 'Pay Cash at Counter' on the web portal.
    Sets status to 'pending_cash', generates 4-digit token_code, and broadcasts
    'new_order' alert to the vendor terminal (triggering audio chime and Queue card).
    """
    order = ORDERS.get(order_id)
    if not order:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Order '{order_id}' not found.",
        )
    validate_cart_and_amount(order)
    if order.get("status") in ("paid", "completed", "cancelled"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Order '{order_id}' is already {order.get('status')}.",
        )

    # 4-digit numeric pickup token code
    token_code = str(random.randint(1000, 9999))
    order["status"] = "pending_cash"
    order["payment_status"] = "CASH_AT_COUNTER"
    order["payment_method"] = "cash"
    order["token_code"] = token_code
    if not order.get("payer_name") or order.get("payer_name") == "UPI Customer":
        order["payer_name"] = f"Cash Customer (#{token_code})"

    save_orders_to_disk()
    summary = _format_order_summary(order_id, order)

    cash_event = {
        "event": "new_order",
        "type": "new_order",
        "order_id": order_id,
        "vendor_id": order["vendor_id"],
        "status": "pending_cash",
        "payment_status": "CASH_AT_COUNTER",
        "payment_method": "cash",
        "token_code": token_code,
        "payer_name": order["payer_name"],
        "total_amount": round(float(order.get("total_amount", 0.0)), 2),
        "auto_delete_after_print": bool(order.get("auto_delete_after_print", False)),
        "order": summary,
    }
    # Broadcast to vendor live queue (triggers chime & card in vendor app)
    await manager.broadcast_to_vendor(order["vendor_id"], cash_event)
    # Broadcast status update to customer tracking WebSocket
    await order_ws_manager.broadcast_to_vendor(order_id, cash_event)
    _trigger_pusher(f"vendor-{order['vendor_id']}", "new-job", cash_event)
    trigger_fcm_notification(
        order["vendor_id"],
        title="🚨 New Print Job (Cash)",
        body=f"Order #{order_id[:8]} • ₹{cash_event['total_amount']}",
        data=cash_event,
    )

    return {
        "success": True,
        "order_id": order_id,
        "status": "pending_cash",
        "payment_method": "cash",
        "token_code": token_code,
        "payer_name": order["payer_name"],
        "order": summary,
    }


@router.post("/{order_id}/confirm-cash")
async def confirm_cash_order(order_id: str):
    """
    Triggered when vendor taps 'PAYMENT DONE & PRINT' for a cash order.
    Records paid_at timestamp, credits session total, and prepares print spooling.
    """
    order = ORDERS.get(order_id)
    if not order:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Order '{order_id}' not found.",
        )
    validate_cart_and_amount(order)
    if order.get("status") == "cancelled":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Order '{order_id}' was cancelled.",
        )

    paid_at = datetime.now().isoformat(timespec="seconds")
    order["status"] = "paid"
    order["payment_method"] = "cash"
    order["paid_at"] = paid_at
    token = order.get("token_code", "Cash")
    if not order.get("payer_name") or order.get("payer_name") == "UPI Customer":
        order["payer_name"] = f"Cash Customer (#{token})"

    save_orders_to_disk()
    summary = _format_order_summary(order_id, order)

    confirm_event = {
        "event": "order_paid",
        "type": "status_update",
        "order_id": order_id,
        "vendor_id": order["vendor_id"],
        "status": "paid",
        "payment_method": "cash",
        "paid_at": paid_at,
        "payer_name": order["payer_name"],
        "auto_delete_after_print": bool(order.get("auto_delete_after_print", False)),
        "order": summary,
    }
    await manager.broadcast_to_vendor(order["vendor_id"], confirm_event)
    await order_ws_manager.broadcast_to_vendor(order_id, confirm_event)

    return {
        "success": True,
        "order_id": order_id,
        "status": "paid",
        "order": summary,
    }


def _format_order_summary(oid: str, order: dict) -> dict:
    """Formats canonical order summary dictionary for list, active queue, and history endpoints."""
    docs = order.get("documents", [])
    if docs:
        p_pages = sum(int(d.get("pages", 1)) * int(d.get("copies", 1)) for d in docs)
        p_copies = sum(int(d.get("copies", 1)) for d in docs)
        has_color = any(d.get("is_color", False) for d in docs)
    else:
        p_pages = int(order.get("total_pages") or order.get("pages") or 1)
        p_copies = int(order.get("copies") or 1)
        has_color = order.get("color_mode") == "color" or bool(order.get("is_color", False))

    created_raw = order.get("created_at")
    if isinstance(created_raw, datetime):
        created_str = created_raw.isoformat()
    else:
        created_str = str(created_raw or "")

    paid_at = order.get("paid_at") or ""
    payment_method = order.get("payment_method") or "upi"
    token_code = order.get("token_code")
    payer_name = order.get("payer_name") or (
        "UPI Customer" if payment_method != "cash" else f"Cash Customer (#{token_code or 'Cash'})"
    )
    clean_order_id = order.get("order_id", oid)
    vendor_id = order.get("vendor_id", "")
    total_amount = round(float(order.get("total_amount", 0.0)), 2)
    short_id = order.get("short_id") or clean_order_id[-6:].upper()
    utr_number = order.get("utr_number") or order.get("utr")
    payment_status = order.get("payment_status") or (
        "PAID" if (order.get("status") or "").lower() == "paid" else "PENDING_PAYMENT"
    )

    return {
        "order_id": clean_order_id,
        "job_id": clean_order_id,
        "short_id": short_id,
        "vendor_id": vendor_id,
        "payer_name": payer_name,
        "payment_method": payment_method,
        "token_code": token_code,
        "paid_at": paid_at,
        "page_count": p_pages,
        "pages": p_pages,
        "total_pages": p_pages,
        "copies": p_copies,
        "is_color": has_color,
        "color_mode": "color" if has_color else "bw",
        "total_amount": total_amount,
        "amount": total_amount,
        "payment_status": payment_status,
        "utr_number": utr_number,
        "auto_delete_after_print": bool(order.get("auto_delete_after_print", False)),
        "status": order.get("status", "awaiting_payment"),
        "page_range": order.get("page_range", "all"),
        "orientation": order.get("orientation", "portrait"),
        "download_url": order.get(
            "download_url",
            f"{DEFAULT_HOST_URL}/api/documents/{clean_order_id}/download",
        ),
        "print_ready_url": order.get(
            "print_ready_url",
            f"{DEFAULT_HOST_URL}/api/documents/{clean_order_id}/print-ready",
        ),
        "transaction_ref": order.get("transaction_ref"),
        "printing_started_at": order.get("printing_started_at"),
        "completed_at": order.get("completed_at"),
        "created_at": created_str,
        "documents": order.get("documents", []),
    }


@router.get("")
@router.get("/")
async def list_orders(
    status: Optional[str] = Query(default=None),
    vendor_id: Optional[str] = Query(default=None),
):
    """
    Returns list of orders across the system or filtered by status ('completed', 'paid', etc.)
    and/or vendor_id, sorted newest-first.
    """
    clean_vendor_id = os.path.basename(vendor_id.strip()) if vendor_id else None
    target_status = status.strip().lower() if status else None
    results = []

    for oid, order in ORDERS.items():
        if clean_vendor_id and order.get("vendor_id") != clean_vendor_id:
            continue
        if target_status and order.get("status", "").lower() != target_status:
            continue
        results.append(_format_order_summary(oid, order))

    results.sort(
        key=lambda x: str(x.get("paid_at") or x.get("created_at") or ""),
        reverse=True,
    )
    return {"orders": results}


@router.get("/vendor/{vendor_id}")
async def get_vendor_active_orders(
    vendor_id: str,
    status: Optional[str] = Query(default=None),
):
    """
    Returns active (pending_payment and paid) orders for a given vendor.
    Allows Flutter vendor app to immediately populate its queue on launch/reconnect.
    Optionally filters by status if provided.
    """
    clean_vendor_id = os.path.basename(vendor_id.strip())
    target_status = status.strip().lower() if status else None
    orders_list = []

    for oid, order in ORDERS.items():
        if order.get("vendor_id") != clean_vendor_id:
            continue
        curr_status = (order.get("status") or "").lower()
        if target_status:
            if curr_status != target_status:
                continue
        else:
            # Only active orders requiring vendor action: paid, pending_cash, cash_at_counter, upi_claimed, paid_queued, printing, or PAYMENT_CLAIMED / CASH_AT_COUNTER
            # Unpaid draft uploads ('awaiting_payment', 'pending_payment') are excluded.
            if curr_status not in ("paid", "pending_cash", "cash_at_counter", "upi_claimed", "paid_queued", "printing") and order.get("payment_status") not in ("PAYMENT_CLAIMED", "UPI_CLAIMED", "CASH_AT_COUNTER"):
                continue
        orders_list.append(_format_order_summary(oid, order))

    orders_list.sort(
        key=lambda x: str(x.get("paid_at") or x.get("created_at") or ""),
        reverse=True,
    )
    return {"orders": orders_list}


@router.get("/vendor/{vendor_id}/history")
async def get_vendor_order_history(vendor_id: str):
    """
    Returns completed print orders for a given vendor, sorted newest-first with
    UPI payer name and payment timestamps for the vendor app History tab.
    """
    clean_vendor_id = os.path.basename(vendor_id.strip())
    history = [
        _format_order_summary(oid, order)
        for oid, order in ORDERS.items()
        if order.get("vendor_id") == clean_vendor_id
        and (order.get("status") or "").lower() == "completed"
    ]
    history.sort(
        key=lambda x: str(x.get("paid_at") or x.get("created_at") or ""),
        reverse=True,
    )
    return {"orders": history}


@router.delete("/vendor/{vendor_id}/history")
async def delete_vendor_order_history_alias(vendor_id: str):
    """Alias for deleting vendor order history on the orders router."""
    from app.api.routes_vendor import delete_vendor_history
    return await delete_vendor_history(vendor_id)


@router.get("/{order_id}/payment-info")
async def get_payment_info(order_id: str):
    """
    Returns server-locked print cost amount, short_id, vendor's shop_name, upi_id,
    and pre-built NPCI UPI intent URI for zero-fee customer settlement.
    """
    order = ORDERS.get(order_id)
    if not order:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Order/Job '{order_id}' not found.",
        )

    validate_cart_and_amount(order)
    clean_vendor_id = os.path.basename(order.get("vendor_id", "").strip())
    if not clean_vendor_id:
        clean_vendor_id = "kiosk"
    vendor = get_vendor_profile(clean_vendor_id)
    shop_name = vendor.get("vendor_name") or f"{clean_vendor_id.capitalize()}'s Print Shop"
    upi_id = vendor.get("upi_id") or DEFAULT_VENDOR_UPI_ID
    amount = round(float(order.get("total_amount", 0.0)), 2)
    short_id = order.get("short_id") or order_id[-6:].upper()
    payment_status = order.get("payment_status") or (
        "PAID" if order.get("status") == "paid" else "PENDING_PAYMENT"
    )
    utr_number = order.get("utr_number") or order.get("utr")

    encoded_shop = urllib.parse.quote(shop_name)
    upi_uri = f"upi://pay?pa={upi_id}&pn={encoded_shop}&am={amount:.2f}&cu=INR&tn=PrintPulse-{short_id}"

    return {
        "job_id": order_id,
        "order_id": order_id,
        "short_id": short_id,
        "amount": amount,
        "shop_name": shop_name,
        "upi_id": upi_id,
        "upi_uri": upi_uri,
        "payment_status": payment_status,
        "utr_number": utr_number,
    }


@router.post("/{order_id}/claim-paid")
async def claim_paid_order(
    order_id: str,
    payload: Optional[ClaimPaymentRequest] = Body(default=None),
):
    """
    Allows customer to claim payment made via UPI app with optional 12-digit UTR number.
    Transitions payment_status to 'PAYMENT_CLAIMED' and broadcasts real-time alert to vendor.
    """
    order = ORDERS.get(order_id)
    if not order:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Order/Job '{order_id}' not found.",
        )

    submitted_amount = payload.amount if payload and payload.amount is not None else None
    validate_cart_and_amount(order, submitted_amount=submitted_amount)
    utr = payload.utr_number.strip() if payload and payload.utr_number else None
    order["payment_status"] = "PAYMENT_CLAIMED"
    order["status"] = "UPI_CLAIMED"
    if utr:
        order["utr_number"] = utr
        order["utr"] = utr
    if payload and payload.payer_name and payload.payer_name.strip():
        order["payer_name"] = payload.payer_name.strip()

    save_orders_to_disk()
    summary = _format_order_summary(order_id, order)

    claim_event = {
        "event": "payment-claimed",
        "type": "payment-claimed",
        "order_id": order_id,
        "job_id": order_id,
        "vendor_id": order["vendor_id"],
        "payment_status": "PAYMENT_CLAIMED",
        "status": "UPI_CLAIMED",
        "utr_number": utr,
        "amount": round(float(order.get("total_amount", 0.0)), 2),
        "payer_name": order.get("payer_name") or "UPI Customer",
        "auto_delete_after_print": bool(order.get("auto_delete_after_print", False)),
        "order": summary,
    }
    # Broadcast to vendor live queue (triggers notification in vendor app)
    await manager.broadcast_to_vendor(order["vendor_id"], claim_event)
    # Broadcast to customer live tracker
    await order_ws_manager.broadcast_to_vendor(order_id, claim_event)
    _trigger_pusher(f"vendor-{order['vendor_id']}", "payment-claimed", claim_event)
    _trigger_pusher(f"order-{order_id}", "payment-claimed", claim_event)
    trigger_fcm_notification(
        order["vendor_id"],
        title="💰 Payment Claimed (UPI)",
        body=f"Order #{order_id[:8]} • ₹{claim_event['amount']} • UTR: {claim_event['utr_number']}",
        data=claim_event,
    )

    return {
        "success": True,
        "status": "success",
        "payment_status": "PAYMENT_CLAIMED",
        "job_id": order_id,
        "order_id": order_id,
        "utr_number": utr,
        "order": summary,
    }


@router.post("/{order_id}/reject")
@router.post("/{order_id}/reject-payment")
async def reject_order_payment(order_id: str):
    """Explicit endpoint to reject claimed payment for an order and remove it from vendor queue."""
    req = VerifyPaymentRequest(approved=False, verified_by="vendor_dashboard")
    return await verify_order_payment(order_id, req)


@router.post("/{order_id}/verify-payment")
async def verify_order_payment(
    order_id: str,
    payload: Optional[VerifyPaymentRequest] = Body(default=None),
):
    """
    Confirms UPI settlement for an order (via webhook or shopkeeper approval)
    and broadcasts an immediate 'payment-verified' / 'order_paid' event to vendor and customer.
    If approved is false, sets payment_status to 'REJECTED' and notifies customer to retry.
    """
    clean_order_id = os.path.basename(order_id.strip())
    order = ORDERS.get(clean_order_id) or ORDERS.get(order_id)
    if not order:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Order '{order_id}' not found.",
        )

    # Handle explicit rejection
    if payload and payload.approved is False:
        # Idempotent return if already marked rejected
        if order.get("payment_status") == "REJECTED" or order.get("status") == "rejected":
            summary = _format_order_summary(clean_order_id, order)
            return {
                "status": "rejected",
                "payment_status": "REJECTED",
                "approved": False,
                "order_id": clean_order_id,
                "job_id": clean_order_id,
                "vendor_id": order["vendor_id"],
                "order": summary,
            }

        order["payment_status"] = "REJECTED"
        order["status"] = "rejected"
        save_orders_to_disk()
        summary = _format_order_summary(clean_order_id, order)
        reject_event = {
            "event": "payment-verified",
            "type": "payment-verified",
            "order_id": clean_order_id,
            "job_id": clean_order_id,
            "vendor_id": order["vendor_id"],
            "status": "rejected",
            "payment_status": "REJECTED",
            "approved": False,
            "order": summary,
        }
        rejected_status_event = {
            "type": "status_update",
            "event": "order_rejected",
            "order_id": clean_order_id,
            "vendor_id": order["vendor_id"],
            "status": "rejected",
            "payment_status": "REJECTED",
            "order": summary,
        }
        await manager.broadcast_to_vendor(order["vendor_id"], reject_event)
        await order_ws_manager.broadcast_to_vendor(clean_order_id, reject_event)
        _trigger_pusher(f"vendor-{order['vendor_id']}", "payment-verified", reject_event)
        _trigger_pusher(f"order-{clean_order_id}", "payment-verified", reject_event)

        return {
            "status": "rejected",
            "payment_status": "REJECTED",
            "approved": False,
            "order_id": clean_order_id,
            "job_id": clean_order_id,
            "vendor_id": order["vendor_id"],
            "order": summary,
        }

    if order.get("status") == "cancelled":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Order '{order_id}' was cancelled and cannot be marked paid.",
        )

    # Strict Cart & Amount Validation: compare submitted amount against server-side re-calculation
    submitted_amount = payload.amount if payload and payload.amount is not None else None
    if submitted_amount is not None:
        validate_cart_and_amount(order, submitted_amount=submitted_amount)
    else:
        # Vendor terminal verification: check if cart was invalidated or cancelled
        if order.get("status") == "cancelled" or order.get("cart_invalidated"):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Cart modified after payment initiation. Please restart checkout.",
            )

    already_paid = order.get("status") == "paid"
    paid_at = datetime.now().isoformat(timespec="seconds")
    order["status"] = "paid"
    order["payment_status"] = "PAID"
    order["payment_method"] = "upi"
    if not order.get("paid_at"):
        order["paid_at"] = paid_at
    payer_name = None
    if payload:
        raw_utr = payload.utr_number or payload.utr
        if raw_utr:
            order["utr"] = raw_utr.strip()
            order["utr_number"] = raw_utr.strip()
        if payload.transaction_ref:
            order["transaction_ref"] = payload.transaction_ref.strip()
        order["verified_by"] = payload.verified_by
        if payload.payer_name and payload.payer_name.strip():
            payer_name = payload.payer_name.strip()
        elif payload.payer_vpa and payload.payer_vpa.strip():
            payer_name = payload.payer_vpa.strip().split("@")[0].replace(".", " ").title()

    if payer_name:
        order["payer_name"] = payer_name
    elif not order.get("payer_name"):
        order["payer_name"] = "UPI Customer"

    save_orders_to_disk()
    summary = _format_order_summary(order_id, order)
    event_payload = _build_paid_event_payload(order)
    verified_event = {
        "event": "payment-verified",
        "type": "payment-verified",
        "order_id": order_id,
        "job_id": order_id,
        "vendor_id": order["vendor_id"],
        "status": "paid",
        "payment_status": "PAID",
        "approved": True,
        "order": summary,
    }

    # Broadcast to vendor and customer channels
    await manager.broadcast_to_vendor(order["vendor_id"], event_payload)
    await manager.broadcast_to_vendor(order["vendor_id"], verified_event)
    await order_ws_manager.broadcast_to_vendor(order_id, {**event_payload, "event": "order_paid", "type": "payment-verified"})
    await order_ws_manager.broadcast_to_vendor(order_id, verified_event)
    _trigger_pusher(f"vendor-{order['vendor_id']}", "new-job", event_payload)
    _trigger_pusher(f"vendor-{order['vendor_id']}", "payment-verified", verified_event)
    _trigger_pusher(f"order-{order_id}", "payment-verified", verified_event)
    trigger_fcm_notification(
        order["vendor_id"],
        title="✅ Order Paid & Ready to Print",
        body=f"Order #{order_id[:8]} • ₹{event_payload.get('order', {}).get('total_amount', '')}",
        data=event_payload,
    )

    return {
        "status": "paid",
        "payment_status": "PAID",
        "approved": True,
        "already_paid": already_paid,
        "order_id": order_id,
        "job_id": order_id,
        "vendor_id": order["vendor_id"],
        "order": summary,
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
