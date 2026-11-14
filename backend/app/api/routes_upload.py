import io
import json
import mimetypes
import os
import shutil
import tempfile
import traceback
import uuid
from datetime import datetime
from typing import Dict, List, Optional
from fastapi import APIRouter, File, Form, HTTPException, UploadFile, status
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from PIL import Image, ImageOps
from pypdf import PdfReader, PdfWriter
import pymupdf
from app.core.pricing import build_upi_uri, compute_order_amount
from app.core.pdf_processor import build_print_ready_pdf, parse_page_range
from app.api.routes_vendor import get_vendor_profile, manager

router = APIRouter()

UPLOAD_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "uploads")
os.makedirs(UPLOAD_DIR, exist_ok=True)

DEFAULT_HOST_URL = (
    os.getenv("API_BASE_URL")
    or os.getenv("SHOP_BASE_URL", "http://192.168.1.41:8000")
).rstrip("/")

# Persistent order store across server reloads
ORDERS_FILE = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "orders_store.json")
)


def _load_orders() -> Dict[str, dict]:
    if os.path.exists(ORDERS_FILE):
        try:
            with open(ORDERS_FILE, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_orders_to_disk() -> None:
    try:
        with open(ORDERS_FILE, "w") as f:
            json.dump(ORDERS, f, indent=2, default=str)
    except Exception:
        pass


ORDERS: Dict[str, dict] = _load_orders()


@router.post("/batch-upload")
async def batch_upload_documents(
    vendor_id: str = Form(...),
    files: List[UploadFile] = File(...),
    copies: int = Form(default=1),
    is_color: bool = Form(default=False),
    page_range: Optional[str] = Form(default="all"),
    orientation: Optional[str] = Form(default="portrait"),
    items_config: Optional[str] = Form(default=None),
):
    if not files:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No files selected.",
        )

    # Parse optional per-document copies/color overrides from customer portal
    parsed_configs: List[dict] = []
    if items_config:
        try:
            loaded = json.loads(items_config)
            if isinstance(loaded, list):
                parsed_configs = loaded
        except Exception:
            parsed_configs = []

    # Sanitize vendor_id to prevent directory traversal
    clean_vendor_id = os.path.basename(vendor_id.strip())
    if not clean_vendor_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid vendor ID.",
        )

    vendor_upload_dir = os.path.join(UPLOAD_DIR, clean_vendor_id)
    os.makedirs(vendor_upload_dir, exist_ok=True)

    vendor = get_vendor_profile(clean_vendor_id)
    bw_price = float(vendor.get("bw_price", 2.0))
    color_price = float(vendor.get("color_price", 10.0))

    order_id = f"ORD-{uuid.uuid4().hex[:6].upper()}"
    allowed_types = ["application/pdf", "image/jpeg", "image/png"]
    processed_files = []
    saved_filepaths = []

    for idx, file in enumerate(files):
        if not file.filename:
            continue

        if file.content_type not in allowed_types:
            # Clean up previously saved files in this batch before failing
            for path in saved_filepaths:
                if os.path.exists(path):
                    os.remove(path)
            raise HTTPException(
                status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
                detail=f"Unsupported file type: '{file.filename}'. Only PDF, JPG, and PNG are allowed.",
            )

        doc_id = str(uuid.uuid4())
        file_ext = os.path.splitext(file.filename)[1].lower()
        # Staged files follow {order_id}_{doc_id}{file_ext} format
        staged_filename = f"{order_id}_{doc_id}{file_ext}"
        staged_filepath = os.path.join(vendor_upload_dir, staged_filename)

        # Stream file to disk in vendor-isolated directory
        try:
            with open(staged_filepath, "wb") as buffer:
                shutil.copyfileobj(file.file, buffer)
            saved_filepaths.append(staged_filepath)
        except Exception as exc:
            for path in saved_filepaths:
                if os.path.exists(path):
                    os.remove(path)
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"Failed to save '{file.filename}': {str(exc)}",
            )

        # Compute page count (1 for images, actual count for PDFs)
        total_pages = 1
        if file.content_type == "application/pdf":
            try:
                reader = PdfReader(staged_filepath)
                total_pages = len(reader.pages)
                if total_pages == 0:
                    raise ValueError("PDF has 0 pages.")
            except Exception as exc:
                for path in saved_filepaths:
                    if os.path.exists(path):
                        os.remove(path)
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"Corrupted or invalid PDF '{file.filename}': {str(exc)}",
                )

        # Calculate individual item pricing (honor per-item config when supplied)
        item_cfg = parsed_configs[idx] if idx < len(parsed_configs) and isinstance(parsed_configs[idx], dict) else {}
        item_copies = int(item_cfg.get("copies", copies) or copies)
        item_is_color = bool(item_cfg.get("is_color", is_color))
        item_page_range = str(item_cfg.get("page_range", page_range or "all")).strip() or "all"
        default_orient = (orientation or "portrait").strip().lower()
        if default_orient not in ("portrait", "landscape"):
            default_orient = "portrait"
        item_orientation = str(item_cfg.get("orientation", default_orient)).strip().lower()
        if item_orientation not in ("portrait", "landscape"):
            item_orientation = default_orient
        effective_pages = (
            len(parse_page_range(item_page_range, total_pages))
            if file.content_type == "application/pdf"
            else 1
        )

        try:
            pricing = compute_order_amount(
                pages=effective_pages,
                copies=item_copies,
                is_color=item_is_color,
                bw_rate=bw_price,
                color_rate=color_price,
            )
        except ValueError as exc:
            for path in saved_filepaths:
                if os.path.exists(path):
                    os.remove(path)
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)
            )

        file_size_kb = round(os.path.getsize(staged_filepath) / 1024, 1)

        processed_files.append(
            {
                "doc_id": doc_id,
                "original_filename": file.filename,
                "staged_file": staged_filename,
                "staged_path": f"/uploads/{clean_vendor_id}/{staged_filename}",
                "download_url": f"{DEFAULT_HOST_URL}/api/documents/{order_id}/download?doc_id={doc_id}",
                "pages": pricing.pages,
                "copies": pricing.copies,
                "is_color": pricing.is_color,
                "page_range": item_page_range,
                "orientation": item_orientation,
                "rate_per_page": pricing.rate_per_page,
                "total_amount": pricing.total_amount,
                "size_kb": file_size_kb,
            }
        )

    total_amount = round(sum(item["total_amount"] for item in processed_files), 2)
    total_pages = sum(item["pages"] * item["copies"] for item in processed_files)
    total_copies = sum(item["copies"] for item in processed_files)
    has_color = any(item["is_color"] for item in processed_files)
    primary_orientation = (
        processed_files[0]["orientation"]
        if processed_files
        else (orientation or "portrait").strip().lower()
    )
    if primary_orientation not in ("portrait", "landscape"):
        primary_orientation = "portrait"
    transaction_ref = f"TXN_{order_id}"
    vendor = get_vendor_profile(clean_vendor_id)
    upi_uri = build_upi_uri(
        vendor_vpa=vendor["upi_id"],
        vendor_name=vendor["vendor_name"],
        total_amount=total_amount,
        order_id=order_id,
        transaction_ref=transaction_ref,
    )

    # Store order info for order lifecycle, UPI verification, and cancellation
    ORDERS[order_id] = {
        "order_id": order_id,
        "vendor_id": clean_vendor_id,
        "files": saved_filepaths,
        "documents": processed_files,
        "total_amount": total_amount,
        "pages": total_pages,
        "total_pages": total_pages,
        "copies": total_copies,
        "color_mode": "color" if has_color else "bw",
        "page_range": (page_range or "all").strip() or "all",
        "orientation": primary_orientation,
        "download_url": f"{DEFAULT_HOST_URL}/api/documents/{order_id}/download",
        "print_ready_url": f"{DEFAULT_HOST_URL}/api/documents/{order_id}/print-ready",
        "transaction_ref": transaction_ref,
        "upi_uri": upi_uri,
        "created_at": datetime.now(),
        "status": "pending_payment",
    }
    save_orders_to_disk()

    # Broadcast job payload to vendor's live WebSocket connection ONLY
    payload = {
        "event": "NEW_PRINT_JOB",
        "order_id": order_id,
        "vendor_id": clean_vendor_id,
        "timestamp": datetime.now().strftime("%I:%M %p"),
        "status": "pending_payment",
        "total_amount": total_amount,
        "total_pages": total_pages,
        "copies": total_copies,
        "color_mode": "color" if has_color else "bw",
        "page_range": (page_range or "all").strip() or "all",
        "orientation": primary_orientation,
        "download_url": f"{DEFAULT_HOST_URL}/api/documents/{order_id}/download",
        "print_ready_url": f"{DEFAULT_HOST_URL}/api/documents/{order_id}/print-ready",
        "documents": processed_files,
    }
    await manager.broadcast_to_vendor(clean_vendor_id, payload)

    return {
        "order_id": order_id,
        "vendor_id": clean_vendor_id,
        "uploaded_documents": processed_files,
        "total_amount": total_amount,
        "total_pages": total_pages,
        "copies": total_copies,
        "color_mode": "color" if has_color else "bw",
        "page_range": (page_range or "all").strip() or "all",
        "orientation": primary_orientation,
        "download_url": f"{DEFAULT_HOST_URL}/api/documents/{order_id}/download",
        "print_ready_url": f"{DEFAULT_HOST_URL}/api/documents/{order_id}/print-ready",
        "transaction_ref": transaction_ref,
        "upi_uri": upi_uri,
        "status": "pending_payment",
    }


def delete_order_files(order_id: str, order: Optional[dict] = None) -> List[str]:
    """
    Permanently deletes all staged files and compiled artifacts associated with an order
    matching {order_id}_* or {order_id}.* or paths in order['files'] from disk.
    Guarantees near-zero disk usage on completed or cancelled orders.
    """
    deleted_files = []
    if not order and order_id in ORDERS:
        order = ORDERS.get(order_id)

    # 1. Clean tracked files from order dictionary
    if order:
        for filepath in order.get("files", []):
            try:
                if os.path.exists(filepath):
                    os.remove(filepath)
                    deleted_files.append(os.path.basename(filepath))
            except (FileNotFoundError, OSError):
                pass

    # 2. Clean any staged files in vendor directories matching {order_id}_* or {order_id}.*
    if os.path.exists(UPLOAD_DIR):
        for v_dir_name in os.listdir(UPLOAD_DIR):
            v_dir = os.path.join(UPLOAD_DIR, v_dir_name)
            if os.path.isdir(v_dir):
                for fname in os.listdir(v_dir):
                    if fname.startswith(f"{order_id}_") or fname.startswith(f"{order_id}."):
                        fpath = os.path.join(v_dir, fname)
                        try:
                            os.remove(fpath)
                            if fname not in deleted_files:
                                deleted_files.append(fname)
                        except (FileNotFoundError, OSError):
                            pass
    return deleted_files


@router.post("/orders/{order_id}/cancel")
async def cancel_order(order_id: str):
    """
    Cancels an order and permanently deletes order-related files matching {order_id}_* from disk.
    Broadcasts the cancellation event to the vendor's active WebSocket connection.
    """
    order = ORDERS.get(order_id)
    vendor_id = order.get("vendor_id") if order else None
    deleted_files = delete_order_files(order_id, order)
    if order:
        order["status"] = "cancelled"
        save_orders_to_disk()

    if not order and not deleted_files:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Order '{order_id}' not found.",
        )

    # Notify vendor WebSocket about cancellation
    if vendor_id:
        try:
            await manager.broadcast_to_vendor(
                vendor_id,
                {
                    "event": "ORDER_CANCELLED",
                    "order_id": order_id,
                    "vendor_id": vendor_id,
                    "message": f"Order {order_id} was cancelled and files matching {order_id}_* were removed.",
                },
            )
        except Exception:
            pass

    return {
        "status": "cancelled",
        "order_id": order_id,
        "vendor_id": vendor_id,
        "deleted_files": deleted_files,
        "message": f"Order '{order_id}' has been cancelled and staged files matching '{order_id}_*' were deleted.",
    }


def _collect_order_print_entries(order_id: str) -> tuple:
    """Resolves staged filepaths and metadata for `order_id` from memory or disk."""
    clean_order_id = os.path.basename(order_id.strip())
    order = ORDERS.get(clean_order_id)
    document_entries = []

    if order:
        if order.get("status") == "cancelled":
            raise HTTPException(
                status_code=status.HTTP_410_GONE,
                detail=f"Order '{clean_order_id}' was cancelled.",
            )

        order_vendor_id = order.get("vendor_id", "")
        order_color_mode = order.get("color_mode", "bw")
        order_copies = int(order.get("copies") or 1)
        order_page_range = order.get("page_range") or "all"
        order_orientation = (order.get("orientation") or "portrait").strip().lower()

        for doc in order.get("documents", []):
            staged_file = doc.get("staged_file", "")
            fpath = os.path.join(UPLOAD_DIR, order_vendor_id, staged_file)
            if not os.path.exists(fpath):
                alt_path = os.path.join(UPLOAD_DIR, staged_file)
                if os.path.exists(alt_path):
                    fpath = alt_path
            if not os.path.exists(fpath):
                v_dir = os.path.join(UPLOAD_DIR, order_vendor_id)
                if os.path.exists(v_dir):
                    for fn in sorted(os.listdir(v_dir)):
                        if (
                            fn == staged_file
                            or fn.endswith(f"_{staged_file}")
                            or (doc.get("doc_id") and doc["doc_id"] in fn)
                        ):
                            fpath = os.path.join(v_dir, fn)
                            break
            if os.path.exists(fpath):
                document_entries.append(
                    {
                        "filepath": fpath,
                        "copies": int(doc.get("copies") or order_copies or 1),
                        "is_color": bool(doc.get("is_color", False))
                        or (order_color_mode == "color"),
                        "color_mode": "color"
                        if (
                            bool(doc.get("is_color", False))
                            or (order_color_mode == "color")
                        )
                        else "bw",
                        "page_range": doc.get("page_range") or order_page_range,
                        "orientation": (doc.get("orientation") or order_orientation or "portrait").strip().lower(),
                        "doc_id": doc.get("doc_id"),
                        "original_filename": doc.get("original_filename"),
                    }
                )

        if not document_entries and order.get("files"):
            for fpath in order["files"]:
                if os.path.exists(fpath):
                    document_entries.append(
                        {
                            "filepath": fpath,
                            "copies": order_copies,
                            "is_color": order_color_mode.lower() == "color",
                            "color_mode": order_color_mode.lower(),
                            "page_range": order_page_range,
                            "orientation": order_orientation,
                        }
                    )

        if document_entries:
            return document_entries, order_color_mode, order_copies, order_page_range, order_orientation

    # Fallback: scan UPLOAD_DIR for files matching {order_id}_*
    matching_files = []
    if clean_order_id and os.path.exists(UPLOAD_DIR):
        for entry_name in sorted(os.listdir(UPLOAD_DIR)):
            vpath = os.path.join(UPLOAD_DIR, entry_name)
            if os.path.isdir(vpath):
                for fname in sorted(os.listdir(vpath)):
                    if fname.startswith(f"{clean_order_id}_"):
                        matching_files.append(os.path.join(vpath, fname))
            elif entry_name.startswith(f"{clean_order_id}_"):
                matching_files.append(vpath)

    fallback_color = "bw"
    fallback_copies = 1
    fallback_page_range = "all"
    fallback_orientation = "portrait"
    if order:
        fallback_color = order.get("color_mode", "bw")
        fallback_orientation = (order.get("orientation") or "portrait").strip().lower()
        total_p = int(order.get("total_pages") or order.get("pages") or 0)
        if total_p > 0 and len(matching_files) > 0:
            fallback_copies = max(1, total_p // len(matching_files))
        else:
            fallback_copies = int(order.get("copies") or 1)
        fallback_page_range = order.get("page_range") or "all"

    for fpath in matching_files:
        document_entries.append(
            {
                "filepath": fpath,
                "copies": fallback_copies,
                "is_color": fallback_color.lower() == "color",
                "color_mode": fallback_color.lower(),
                "page_range": fallback_page_range,
                "orientation": fallback_orientation,
            }
        )

    return document_entries, fallback_color, fallback_copies, fallback_page_range, fallback_orientation


def assemble_order_pdf(
    document_entries: List[dict],
    order_id: str,
    default_color_mode: str = "bw",
    default_copies: int = 1,
    default_orientation: str = "portrait",
) -> bytes:
    """
    Renders all image and PDF items into a single master PDF document:
      - Images (.png, .jpg, .jpeg, .webp): Sized to full-bleed standard A4 Portrait
        (595.28 x 841.89 pt) or A4 Landscape (841.89 x 595.28 pt) with 20pt margins,
        proportional scaling, and grayscale conversion if B&W.
      - PDFs: Slices requested page range, converted to grayscale if B&W.
      - Repeats pages per each item's copy count.
    """
    master_writer = PdfWriter()

    for entry in document_entries:
        fpath = entry.get("filepath", "")
        if not fpath or not os.path.exists(fpath):
            continue

        item_copies = max(1, int(entry.get("copies") or default_copies or 1))
        item_color_mode = (
            entry.get("color_mode")
            or ("color" if entry.get("is_color") else default_color_mode)
            or "bw"
        ).strip().lower()
        is_bw = item_color_mode == "bw"
        page_range = entry.get("page_range", "all")

        ext = os.path.splitext(fpath)[1].lower()
        item_pages = []

        if ext in (".png", ".jpg", ".jpeg", ".webp"):
            with Image.open(fpath) as raw_img:
                raw_img = ImageOps.exif_transpose(raw_img)
                raw_img.info.pop("dpi", None)
                raw_img.info.pop("icc_profile", None)

                if raw_img.mode in ("RGBA", "LA") or (
                    raw_img.mode == "P" and "transparency" in raw_img.info
                ):
                    raw_rgba = raw_img.convert("RGBA")
                    bg = Image.new("RGBA", raw_rgba.size, (255, 255, 255, 255))
                    bg.paste(raw_rgba, (0, 0), raw_rgba)
                    processed_img = bg.convert("RGB")
                else:
                    processed_img = raw_img.convert("RGB")

                # Resolve orientation: explicit entry orientation > default_orientation > aspect ratio
                item_orient = (
                    entry.get("orientation")
                    or default_orientation
                    or ("landscape" if processed_img.width > processed_img.height else "portrait")
                ).strip().lower()

                if item_orient == "landscape":
                    page_w, page_h = 841.89, 595.28
                else:
                    page_w, page_h = 595.28, 841.89

                margin = 20.0
                avail_w = page_w - (2 * margin)
                avail_h = page_h - (2 * margin)

                img_w, img_h = processed_img.size
                scale = min(avail_w / img_w, avail_h / img_h)
                draw_w = img_w * scale
                draw_h = img_h * scale
                x = (page_w - draw_w) / 2
                y = (page_h - draw_h) / 2

                # Sharpen/rescale source image into high-res buffer
                max_w = int(page_w * 300 / 72)
                max_h = int(page_h * 300 / 72)
                processed_img.thumbnail((max_w, max_h), Image.Resampling.LANCZOS)
                if is_bw:
                    processed_img = processed_img.convert("L")

                img_buf = io.BytesIO()
                processed_img.save(img_buf, format="PNG")
                img_bytes = img_buf.getvalue()

                # Embed centered onto fixed standard A4 PDF page
                doc = pymupdf.open()
                page = doc.new_page(width=page_w, height=page_h)
                content_rect = pymupdf.Rect(x, y, x + draw_w, y + draw_h)
                page.insert_image(
                    content_rect, stream=img_bytes, keep_proportion=True
                )
                pdf_bytes = doc.tobytes()
                doc.close()

                reader = PdfReader(io.BytesIO(pdf_bytes))
                item_pages = list(reader.pages)

        elif ext == ".pdf":
            if not is_bw:
                reader = PdfReader(fpath)
                indices = parse_page_range(page_range, len(reader.pages))
                item_pages = [reader.pages[i] for i in indices]
            else:
                doc = pymupdf.open(fpath)
                indices = parse_page_range(page_range, len(doc))
                out_doc = pymupdf.open()
                for idx in indices:
                    src_page = doc[idx]
                    pix = src_page.get_pixmap(colorspace=pymupdf.csGRAY, dpi=200)
                    new_p = out_doc.new_page(
                        width=src_page.rect.width, height=src_page.rect.height
                    )
                    new_p.insert_image(
                        new_p.rect,
                        stream=pix.tobytes("png"),
                        keep_proportion=True,
                    )
                doc.close()
                pdf_bytes = out_doc.tobytes()
                out_doc.close()
                reader = PdfReader(io.BytesIO(pdf_bytes))
                item_pages = list(reader.pages)
        else:
            continue

        for _ in range(item_copies):
            for p in item_pages:
                master_writer.add_page(p)

    if len(master_writer.pages) == 0:
        raise ValueError(
            f"No printable pages could be assembled for order '{order_id}'."
        )

    out_io = io.BytesIO()
    master_writer.write(out_io)
    return out_io.getvalue()


@router.api_route("/{order_id}/download", methods=["GET", "HEAD"])
async def download_order_document(order_id: str, doc_id: Optional[str] = None):
    """
    Assembles all files attached to `order_id` into a single print-ready PDF
    with grayscale conversion for B&W and copy count expansion.
    Streams back the merged PDF as StreamingResponse.
    """
    clean_order_id = os.path.basename(order_id.strip())
    try:
        (
            document_entries,
            order_color_mode,
            order_copies,
            order_page_range,
            order_orientation,
        ) = _collect_order_print_entries(clean_order_id)

        if not document_entries:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Uploaded document for order '{order_id}' not found.",
            )

        if doc_id:
            filtered = [
                d
                for d in document_entries
                if d.get("doc_id") == doc_id or doc_id in d.get("filepath", "")
            ]
            if filtered:
                document_entries = filtered

        pdf_bytes = assemble_order_pdf(
            document_entries=document_entries,
            order_id=clean_order_id,
            default_color_mode=order_color_mode,
            default_copies=order_copies,
            default_orientation=order_orientation,
        )

        safe_filename = f"{clean_order_id}.pdf"
        return StreamingResponse(
            io.BytesIO(pdf_bytes),
            media_type="application/pdf",
            headers={
                "Content-Disposition": f'inline; filename="{safe_filename}"',
                "Content-Length": str(len(pdf_bytes)),
                "Cache-Control": "no-store",
            },
        )
    except HTTPException:
        raise
    except Exception as exc:
        traceback.print_exc()
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content={
                "error": "Failed to assemble order documents into print-ready PDF",
                "detail": str(exc),
                "order_id": order_id,
            },
        )


@router.get("/{order_id}/print-ready")
async def get_print_ready_pdf(
    order_id: str,
    page_range: Optional[str] = None,
    color_mode: Optional[str] = None,
    copies: Optional[int] = None,
):
    """
    Pre-processes the order's staged documents into a print-ready A4/PDF stream:
      - Filters pages per saved or requested `page_range`
      - Converts pages/images to DeviceGray monochrome when `color_mode == 'bw'`
      - Repeats the page sequence `copies` times so one-tap printing outputs all copies
    """
    (
        document_entries,
        order_color_mode,
        order_copies,
        order_page_range,
        order_orientation,
    ) = _collect_order_print_entries(order_id)

    if not document_entries:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"No staged files found for order '{order_id}'.",
        )

    try:
        pdf_bytes = build_print_ready_pdf(
            document_entries=document_entries,
            order_color_mode=order_color_mode,
            order_copies=order_copies,
            order_page_range=order_page_range,
            override_copies=copies,
            override_color_mode=color_mode,
            override_page_range=page_range,
        )
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(exc),
        )
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to prepare print-ready PDF: {str(exc)}",
        )

    safe_order_id = os.path.basename(order_id.strip())
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={
            "Content-Disposition": f'inline; filename="{safe_order_id}_print_ready.pdf"',
            "Cache-Control": "no-store",
        },
    )


@router.post("/preview-pdf")
async def preview_document_pdf(
    file: Optional[UploadFile] = File(default=None),
    files: Optional[List[UploadFile]] = File(default=None),
    color_mode: str = Form(default="bw"),
    is_color: bool = Form(default=False),
    orientation: str = Form(default="portrait"),
    page_range: Optional[str] = Form(default="all"),
    items_config: Optional[str] = Form(default=None),
):
    """
    Renders an exact preview PDF of the uploaded file(s) applying
    the customer's selected orientation, color mode (B&W/Color), and page range
    with standard A4 dimensions (595.28 x 841.89 pt or 841.89 x 595.28 pt)
    and 20pt margins, identical to the print spooler output.
    """
    upload_files: List[UploadFile] = []
    if file and file.filename:
        upload_files.append(file)
    if files:
        for f in files:
            if f.filename:
                upload_files.append(f)

    if not upload_files:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No files provided for preview.",
        )

    parsed_configs: List[dict] = []
    if items_config:
        try:
            loaded = json.loads(items_config)
            if isinstance(loaded, list):
                parsed_configs = loaded
        except Exception:
            parsed_configs = []

    default_color = "color" if is_color or color_mode.lower() == "color" else "bw"
    default_orient = (orientation or "portrait").strip().lower()
    if default_orient not in ("portrait", "landscape"):
        default_orient = "portrait"

    temp_paths: List[str] = []
    document_entries: List[dict] = []
    temp_dir = os.path.join(tempfile.gettempdir(), "printpulse_previews")
    os.makedirs(temp_dir, exist_ok=True)

    try:
        for idx, f in enumerate(upload_files):
            ext = os.path.splitext(f.filename or "")[1].lower()
            if ext not in (".pdf", ".png", ".jpg", ".jpeg", ".webp"):
                raise HTTPException(
                    status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
                    detail=f"Unsupported preview file format: '{f.filename}'. Only PDF, JPG, and PNG are allowed.",
                )

            tmp_name = f"prev_{uuid.uuid4().hex[:8]}_{idx}{ext}"
            tmp_path = os.path.join(temp_dir, tmp_name)
            with open(tmp_path, "wb") as buf:
                shutil.copyfileobj(f.file, buf)
            temp_paths.append(tmp_path)

            cfg = (
                parsed_configs[idx]
                if idx < len(parsed_configs) and isinstance(parsed_configs[idx], dict)
                else {}
            )
            item_orient = str(cfg.get("orientation", default_orient)).strip().lower()
            if item_orient not in ("portrait", "landscape"):
                item_orient = default_orient
            item_is_color = bool(
                cfg.get("is_color", is_color or (color_mode.lower() == "color"))
            )
            item_color_mode = "color" if item_is_color else "bw"
            item_page_range = str(cfg.get("page_range", page_range or "all")).strip() or "all"

            document_entries.append(
                {
                    "filepath": tmp_path,
                    "copies": 1,
                    "color_mode": item_color_mode,
                    "is_color": item_is_color,
                    "orientation": item_orient,
                    "page_range": item_page_range,
                    "original_filename": f.filename or "preview",
                }
            )

        pdf_bytes = assemble_order_pdf(
            document_entries=document_entries,
            order_id="PREVIEW",
            default_color_mode=default_color,
            default_copies=1,
            default_orientation=default_orient,
        )

        return Response(
            content=pdf_bytes,
            media_type="application/pdf",
            headers={
                "Content-Disposition": 'inline; filename="exact_print_preview.pdf"',
                "Content-Length": str(len(pdf_bytes)),
                "Cache-Control": "no-store",
            },
        )
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to generate print preview: {str(exc)}",
        )
    finally:
        for p in temp_paths:
            if os.path.exists(p):
                try:
                    os.remove(p)
                except Exception:
                    pass
