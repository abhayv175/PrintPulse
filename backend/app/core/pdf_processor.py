import io
import os
from typing import Dict, List, Optional
from PIL import Image, ImageOps
import pymupdf


def parse_page_range(range_str: Optional[str], max_pages: int) -> List[int]:
    """
    Parses a human page-range string (e.g. 'all', '1-3', '1,3-5') into sorted
    0-based page indices bounded by [0, max_pages - 1].
    """
    if max_pages <= 0:
        return []

    cleaned = (range_str or "all").strip().lower()
    if cleaned in ("", "all", "*"):
        return list(range(max_pages))

    selected: List[int] = []
    seen = set()

    for token in cleaned.split(","):
        part = token.strip()
        if not part:
            continue
        if "-" in part:
            bounds = part.split("-", 1)
            try:
                start_page = int(bounds[0].strip())
                end_page = int(bounds[1].strip())
            except ValueError:
                continue
            step = 1 if start_page <= end_page else -1
            for page_num in range(start_page, end_page + step, step):
                if 1 <= page_num <= max_pages:
                    idx = page_num - 1
                    if idx not in seen:
                        seen.add(idx)
                        selected.append(idx)
        else:
            try:
                page_num = int(part)
            except ValueError:
                continue
            if 1 <= page_num <= max_pages:
                idx = page_num - 1
                if idx not in seen:
                    seen.add(idx)
                    selected.append(idx)

    return selected if selected else list(range(max_pages))


def _append_image_to_doc(
    target_doc: pymupdf.Document,
    filepath: str,
    is_bw: bool,
    orientation: str = "portrait",
) -> None:
    """Converts an uploaded JPG/PNG image to A4 PDF (grayscale if B&W) and appends it."""
    with Image.open(filepath) as img:
        img = ImageOps.exif_transpose(img)
        converted = img.convert("L") if is_bw else img.convert("RGB")
        img_buf = io.BytesIO()
        converted.save(img_buf, format="PNG")
        img_bytes = img_buf.getvalue()
        img_w, img_h = converted.size

    is_landscape = (orientation or "").strip().lower() == "landscape"
    if is_landscape:
        page_w, page_h = 841.89, 595.28
    else:
        page_w, page_h = 595.28, 841.89

    margin = 20.0
    avail_w = page_w - (2 * margin)
    avail_h = page_h - (2 * margin)
    scale = min(avail_w / img_w, avail_h / img_h)
    draw_w = img_w * scale
    draw_h = img_h * scale
    x = (page_w - draw_w) / 2
    y = (page_h - draw_h) / 2

    page = target_doc.new_page(width=page_w, height=page_h)
    content_rect = pymupdf.Rect(x, y, x + draw_w, y + draw_h)
    page.insert_image(content_rect, stream=img_bytes, keep_proportion=True)


def _append_pdf_to_doc(
    target_doc: pymupdf.Document,
    filepath: str,
    page_range: Optional[str],
    is_bw: bool,
    dpi: int = 200,
) -> None:
    """Extracts requested page range from a PDF and converts to grayscale if B&W."""
    with pymupdf.open(filepath) as src_doc:
        indices = parse_page_range(page_range, len(src_doc))
        if not indices:
            return

        if is_bw:
            for idx in indices:
                orig_page = src_doc[idx]
                pix = orig_page.get_pixmap(colorspace=pymupdf.csGRAY, dpi=dpi)
                new_page = target_doc.new_page(
                    width=orig_page.rect.width,
                    height=orig_page.rect.height,
                )
                new_page.insert_image(
                    new_page.rect,
                    stream=pix.tobytes("png"),
                    keep_proportion=True,
                )
        else:
            for idx in indices:
                target_doc.insert_pdf(src_doc, from_page=idx, to_page=idx)


def _repeat_doc_pages(doc: pymupdf.Document, copies: int) -> None:
    """Repeats the full page sequence in-place `copies` times without duplicating XObjects."""
    safe_copies = max(1, int(copies or 1))
    page_count = len(doc)
    if safe_copies > 1 and page_count > 0:
        doc.select(list(range(page_count)) * safe_copies)


def build_print_ready_pdf(
    document_entries: List[Dict],
    order_color_mode: str = "bw",
    order_copies: int = 1,
    order_page_range: Optional[str] = "all",
    override_copies: Optional[int] = None,
    override_color_mode: Optional[str] = None,
    override_page_range: Optional[str] = None,
) -> bytes:
    """
    Generates a single consolidated, print-ready PDF byte stream reflecting:
      1. Page range filtering (e.g. '1-3', 'all').
      2. Color mode ('bw' rasterizes pages/images into DeviceGray; 'color' preserves color).
      3. Copy expansion (repeats each page sequence N times so Android PrintManager outputs
         the paid copy count in one tap).
    """
    if not document_entries:
        raise ValueError("Order has no staged files available for printing.")

    final_doc = pymupdf.open()
    normalized_order_color = (
        (override_color_mode or order_color_mode or "bw").strip().lower()
    )
    force_bw = normalized_order_color == "bw"
    single_doc_mode = len(document_entries) == 1

    try:
        for entry in document_entries:
            filepath = entry.get("filepath", "")
            if not filepath or not os.path.exists(filepath):
                continue

            doc_doc = pymupdf.open()
            try:
                if override_color_mode is not None:
                    is_bw = force_bw
                elif force_bw:
                    is_bw = True
                else:
                    is_bw = not bool(entry.get("is_color", True))

                doc_page_range = (
                    override_page_range
                    if override_page_range is not None
                    else entry.get("page_range", order_page_range or "all")
                )

                ext = os.path.splitext(filepath)[1].lower()
                if ext == ".pdf":
                    _append_pdf_to_doc(
                        doc_doc, filepath, doc_page_range, is_bw=is_bw
                    )
                elif ext in (".jpg", ".jpeg", ".png", ".webp"):
                    _append_image_to_doc(
                        doc_doc,
                        filepath,
                        is_bw=is_bw,
                        orientation=entry.get("orientation", "portrait"),
                    )
                else:
                    raise ValueError(f"Unsupported staged file format: {ext}")

                if override_copies is not None:
                    doc_copies = max(1, int(override_copies))
                elif single_doc_mode:
                    doc_copies = max(
                        1, int(order_copies or entry.get("copies") or 1)
                    )
                else:
                    doc_copies = max(1, int(entry.get("copies") or 1))

                if not (override_copies is not None and not single_doc_mode):
                    _repeat_doc_pages(doc_doc, doc_copies)

                if len(doc_doc) > 0:
                    final_doc.insert_pdf(doc_doc)
            finally:
                doc_doc.close()

        if len(final_doc) == 0:
            raise ValueError("No printable pages could be generated for this order.")

        if override_copies is not None and not single_doc_mode:
            _repeat_doc_pages(final_doc, max(1, int(override_copies)))

        return final_doc.tobytes(deflate=True, garbage=3)
    finally:
        final_doc.close()
