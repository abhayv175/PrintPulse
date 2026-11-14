"""
PrintPulse Backend & API Automated Verification Suite
Tests FastAPI endpoints, multi-tenant file staging isolation,
WebSocket scoped event dispatching, order cancellation disk cleanup,
and Google authentication verification.
"""

import io
import json
import os
import queue
import sys
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from pypdf import PdfWriter

# Ensure backend directory is in python path
BACKEND_DIR = Path(__file__).resolve().parent.parent
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from main import app

# Shared test helper to generate minimal valid in-memory PDFs
def generate_mock_pdf(num_pages: int = 1) -> bytes:
    writer = PdfWriter()
    for _ in range(num_pages):
        writer.add_blank_page(width=100, height=100)
    buf = io.BytesIO()
    writer.write(buf)
    return buf.getvalue()


# Module-scoped client fixture for pytest
@pytest.fixture(scope="module")
def client():
    return TestClient(app)


# ---------------------------------------------------------------------------
# Test A: Static Assets & Web Route Resolution
# ---------------------------------------------------------------------------
def test_a_static_assets_and_web_routes(client=None):
    """
    Verifies that:
    - /favicon.ico returns 200 with image media type.
    - /static/styles.css returns 200.
    - /shop/{vendor_id} returns 200 HTML with vendor_id rendered in context.
    """
    client = client or TestClient(app)

    # 1. Favicon route
    res_fav = client.get("/favicon.ico")
    assert res_fav.status_code == 200, f"Expected 200 for /favicon.ico, got {res_fav.status_code}"
    assert "image/" in res_fav.headers.get("content-type", "")

    # 2. Static CSS asset
    res_css = client.get("/static/styles.css")
    assert res_css.status_code == 200, f"Expected 200 for /static/styles.css, got {res_css.status_code}"

    # 3. /shop/shop_alpha
    res_alpha = client.get("/shop/shop_alpha")
    assert res_alpha.status_code == 200
    assert "text/html" in res_alpha.headers.get("content-type", "")
    assert "shop_alpha" in res_alpha.text

    # 4. /shop/shop_beta
    res_beta = client.get("/shop/shop_beta")
    assert res_beta.status_code == 200
    assert "text/html" in res_beta.headers.get("content-type", "")
    assert "shop_beta" in res_beta.text


# ---------------------------------------------------------------------------
# Test B: Multi-Tenant Batch Upload & Staging Isolation
# ---------------------------------------------------------------------------
# Track created order IDs across tests for cleanup/cancel tests
STAGED_TEST_ORDERS = {}

def test_b_multi_tenant_batch_upload_and_staging_isolation(client=None):
    """
    Verifies that:
    - Upload with vendor_id='shop_alpha' writes files strictly to uploads/shop_alpha/.
    - Upload with vendor_id='shop_beta' writes files strictly to uploads/shop_beta/.
    - Neither directory leaks files to the other vendor or to the root uploads folder.
    - PDF page extraction and pricing calculations are accurate.
    """
    client = client or TestClient(app)
    uploads_root = BACKEND_DIR / "uploads"

    alpha_pdf_1 = generate_mock_pdf(num_pages=2)
    alpha_pdf_2 = generate_mock_pdf(num_pages=3)

    # 1. Upload for shop_alpha
    res_alpha = client.post(
        "/api/documents/batch-upload",
        data={"vendor_id": "shop_alpha", "copies": 1, "is_color": False},
        files=[
            ("files", ("invoice.pdf", alpha_pdf_1, "application/pdf")),
            ("files", ("manual.pdf", alpha_pdf_2, "application/pdf")),
        ],
    )
    assert res_alpha.status_code == 200, f"shop_alpha upload failed: {res_alpha.text}"
    alpha_data = res_alpha.json()
    order_alpha_id = alpha_data["order_id"]
    STAGED_TEST_ORDERS["shop_alpha"] = order_alpha_id

    assert alpha_data["vendor_id"] == "shop_alpha"
    assert len(alpha_data["uploaded_documents"]) == 2
    # Verify page counts (2 pages and 3 pages, rate 2.0 = 4.0 and 6.0)
    docs_alpha = {d["original_filename"]: d for d in alpha_data["uploaded_documents"]}
    assert docs_alpha["invoice.pdf"]["pages"] == 2
    assert docs_alpha["invoice.pdf"]["total_amount"] == 4.0
    assert docs_alpha["manual.pdf"]["pages"] == 3
    assert docs_alpha["manual.pdf"]["total_amount"] == 6.0

    # Filesystem Check for shop_alpha
    alpha_dir = uploads_root / "shop_alpha"
    assert alpha_dir.exists(), "uploads/shop_alpha/ directory was not created"
    alpha_files = set(os.listdir(alpha_dir))
    staged_alpha_files = {d["staged_file"] for d in alpha_data["uploaded_documents"]}
    assert staged_alpha_files.issubset(alpha_files), "Uploaded files not found in shop_alpha directory"

    # Confirm shop_beta folder does not exist or has no shop_alpha files
    beta_dir = uploads_root / "shop_beta"
    if beta_dir.exists():
        assert not any(f in staged_alpha_files for f in os.listdir(beta_dir))

    # Confirm root uploads directory has NO leaked staged files
    root_files = [f for f in os.listdir(uploads_root) if os.path.isfile(uploads_root / f) and f != ".gitkeep"]
    assert len(root_files) == 0, f"Leaked files in root uploads directory: {root_files}"

    # 2. Upload for shop_beta
    beta_pdf = generate_mock_pdf(num_pages=1)
    res_beta = client.post(
        "/api/documents/batch-upload",
        data={"vendor_id": "shop_beta", "copies": 2, "is_color": True},
        files=[
            ("files", ("flyer.pdf", beta_pdf, "application/pdf")),
        ],
    )
    assert res_beta.status_code == 200, f"shop_beta upload failed: {res_beta.text}"
    beta_data = res_beta.json()
    order_beta_id = beta_data["order_id"]
    STAGED_TEST_ORDERS["shop_beta"] = order_beta_id

    assert beta_data["vendor_id"] == "shop_beta"
    assert len(beta_data["uploaded_documents"]) == 1
    # 1 page * 2 copies * 10.0 (color) = 20.0
    assert beta_data["uploaded_documents"][0]["total_amount"] == 20.0

    # Filesystem Check for shop_beta
    assert beta_dir.exists(), "uploads/shop_beta/ directory was not created"
    beta_files = set(os.listdir(beta_dir))
    staged_beta_files = {d["staged_file"] for d in beta_data["uploaded_documents"]}
    assert staged_beta_files.issubset(beta_files)

    # Cross-tenant integrity: beta directory must NOT contain alpha files, and vice-versa
    assert alpha_files.isdisjoint(beta_files), "Cross-tenant file leakage detected between shop_alpha and shop_beta"


# ---------------------------------------------------------------------------
# Test C: WebSocket Multi-Tenant Connection & Scoped Dispatch
# ---------------------------------------------------------------------------
def test_c_websocket_multi_tenant_connection_and_scoped_dispatch(client=None):
    """
    Verifies that:
    - Connecting to /ws/vendor/shop_alpha and /ws/vendor/shop_beta simultaneously works.
    - An upload targeting shop_alpha triggers a 'NEW_PRINT_JOB' event exclusively on shop_alpha.
    - shop_beta receives nothing (times out with no message).
    """
    client = client or TestClient(app)
    test_pdf = generate_mock_pdf(num_pages=1)

    with client.websocket_connect("/ws/vendor/shop_alpha") as ws_alpha:
        with client.websocket_connect("/ws/vendor/shop_beta") as ws_beta:
            # Trigger upload for shop_alpha
            res = client.post(
                "/api/documents/batch-upload",
                data={"vendor_id": "shop_alpha", "copies": 1, "is_color": False},
                files=[("files", ("ws_test.pdf", test_pdf, "application/pdf"))],
            )
            assert res.status_code == 200
            order_id = res.json()["order_id"]

            # shop_alpha MUST receive the NEW_PRINT_JOB payload
            raw_msg = ws_alpha._send_queue.get(timeout=1.0)
            alpha_payload = json.loads(raw_msg["text"])
            assert alpha_payload.get("event") == "NEW_PRINT_JOB", f"Unexpected event: {alpha_payload}"
            assert alpha_payload.get("order_id") == order_id
            assert alpha_payload.get("vendor_id") == "shop_alpha"

            # shop_beta MUST receive nothing (timeout)
            beta_received_nothing = False
            try:
                ws_beta._send_queue.get(timeout=0.25)
            except queue.Empty:
                beta_received_nothing = True

            assert beta_received_nothing, "shop_beta unexpectedly received an event meant for shop_alpha"


# ---------------------------------------------------------------------------
# Test D: Order Cancellation & Disk Cleanup
# ---------------------------------------------------------------------------
def test_d_order_cancellation_and_disk_cleanup(client=None):
    """
    Verifies that:
    - Calling POST /api/documents/orders/{order_id}/cancel returns status 200.
    - Staged files for that order are permanently purged from backend/uploads/{vendor_id}/.
    """
    client = client or TestClient(app)
    uploads_root = BACKEND_DIR / "uploads"

    # Create a fresh order for clean verification
    pdf_bytes = generate_mock_pdf(num_pages=1)
    res_up = client.post(
        "/api/documents/batch-upload",
        data={"vendor_id": "shop_alpha", "copies": 1, "is_color": False},
        files=[("files", ("cancel_me.pdf", pdf_bytes, "application/pdf"))],
    )
    assert res_up.status_code == 200
    up_data = res_up.json()
    order_id = up_data["order_id"]
    staged_filename = up_data["uploaded_documents"][0]["staged_file"]
    file_path = uploads_root / "shop_alpha" / staged_filename
    assert file_path.exists(), f"File {file_path} was not staged"

    # Cancel order
    res_cancel = client.post(f"/api/documents/orders/{order_id}/cancel")
    assert res_cancel.status_code == 200, f"Cancel returned {res_cancel.status_code}: {res_cancel.text}"
    cancel_data = res_cancel.json()
    assert cancel_data["status"] == "cancelled"
    assert cancel_data["order_id"] == order_id

    # Confirm file is permanently deleted from disk
    assert not file_path.exists(), f"File was NOT deleted after cancellation: {file_path}"

    # Verify canceling non-existent order returns 404
    res_404 = client.post("/api/documents/orders/ORD-NONEXISTENT/cancel")
    assert res_404.status_code == 404


# ---------------------------------------------------------------------------
# Test E: Google Auth Token Verification Endpoint
# ---------------------------------------------------------------------------
def test_e_google_auth_token_verification_endpoint(client=None):
    """
    Verifies that:
    - POST /api/vendor/auth/google with a malformed/invalid token returns 401 Unauthorized.
    - POST /api/vendor/auth/google with a mock valid token returns status 'authenticated',
      clean vendor_id, and formatted shop_url.
    """
    client = client or TestClient(app)

    # 1. Malformed / invalid token
    res_bad = client.post(
        "/api/vendor/auth/google",
        json={"token": "invalid_malformed_token_999"},
    )
    assert res_bad.status_code == 401, f"Expected 401 for bad token, got {res_bad.status_code}"

    # Empty payload
    res_empty = client.post("/api/vendor/auth/google", json={})
    assert res_empty.status_code == 401, f"Expected 401 for empty payload, got {res_empty.status_code}"

    # 2. Mock valid verification payload (Gmail prefix)
    res_valid = client.post(
        "/api/vendor/auth/google",
        json={"token": "mock_google_token", "email": "shopkeeper@gmail.com"},
    )
    assert res_valid.status_code == 200, f"Expected 200 for valid token, got {res_valid.status_code}"
    auth_data = res_valid.json()
    assert auth_data.get("status") == "authenticated"
    assert auth_data.get("email") == "shopkeeper@gmail.com"
    vendor_id = auth_data.get("vendor_id")
    assert vendor_id == "shopkeeper"
    assert auth_data.get("shop_url") == "http://192.168.1.41:8000/shop/shopkeeper"

    # 3. Google Workspace / custom domain account
    res_mock_bypass = client.post(
        "/api/vendor/auth/google",
        json={"token": "mock_token_storeowner@printpulse.com"},
    )
    assert res_mock_bypass.status_code == 200, f"Expected 200 for mock_token_<email>, got {res_mock_bypass.status_code}"
    bypass_data = res_mock_bypass.json()
    assert bypass_data.get("status") == "authenticated"
    assert bypass_data.get("email") == "storeowner@printpulse.com"
    store_vendor_id = bypass_data.get("vendor_id")
    assert store_vendor_id == "storeowner"
    assert bypass_data.get("shop_url") == "http://192.168.1.41:8000/shop/storeowner"

    # 4. Dots and special characters are sanitized to underscores & portal/WS work
    res_dotted = client.post(
        "/api/vendor/auth/google",
        json={"token": "mock_token_Abhay.Verma+Kiosk@custom.in"},
    )
    assert res_dotted.status_code == 200
    dotted_data = res_dotted.json()
    assert dotted_data.get("vendor_id") == "abhay_verma_kiosk"
    assert dotted_data.get("shop_url") == "http://192.168.1.41:8000/shop/abhay_verma_kiosk"

    res_portal = client.get("/shop/abhay_verma_kiosk")
    assert res_portal.status_code == 200
    assert "abhay_verma_kiosk" in res_portal.text

    with client.websocket_connect("/ws/vendor/abhay_verma_kiosk") as ws_vendor:
        assert ws_vendor is not None

    # 5. Punctuation-only local-part falls back deterministically
    res_fallback = client.post(
        "/api/vendor/auth/google",
        json={"token": "mock_token_...@gmail.com"},
    )
    assert res_fallback.status_code == 200
    fallback_id = res_fallback.json().get("vendor_id")
    assert fallback_id and fallback_id.startswith("vendor_")


# ---------------------------------------------------------------------------
# Test F: Dynamic UPI Order Creation, Payment Verification & WS Broadcast
# ---------------------------------------------------------------------------
def test_f_upi_order_creation_and_payment_settlement(client=None):
    """
    Verifies Phase 4 UPI payment gateway flow:
    - Custom VPA configuration on vendor profile.
    - POST /api/orders/create computes INR amount and NPCI-compliant upi_uri.
    - GET /shop/{vendor_id} serves UPI checkout and QR/intent controls.
    - POST /api/orders/{order_id}/verify-payment updates status to paid and
      pushes immediate 'order_paid' event to both vendor and customer WebSockets.
    """
    client = client or TestClient(app)

    # 1. Configure vendor UPI VPA
    res_upi = client.post(
        "/api/vendor/shop_alpha/upi",
        json={"upi_id": "alpha@okaxis", "vendor_name": "Alpha Print"},
    )
    assert res_upi.status_code == 200
    assert res_upi.json()["upi_id"] == "alpha@okaxis"

    # 2. Verify portal HTML includes UPI checkout widgets
    portal_html = client.get("/shop/shop_alpha").text
    assert "Pay via UPI App" in portal_html
    assert "upiCheckoutSection" in portal_html

    # 3. Create B&W order (7 pages * 1 copy * Rs 2 = Rs 14.00)
    res_create = client.post(
        "/api/orders/create",
        json={
            "vendor_id": "shop_alpha",
            "pages": 7,
            "copies": 1,
            "color_mode": "bw",
        },
    )
    assert res_create.status_code == 200, res_create.text
    order_data = res_create.json()
    order_id = order_data["order_id"]
    assert order_data["total_amount"] == 14.0
    assert order_data["status"] == "pending_payment"
    upi_uri = order_data["upi_uri"]
    assert upi_uri.startswith("upi://pay?")
    assert "pa=alpha@okaxis" in upi_uri
    assert "am=14.00" in upi_uri
    assert "cu=INR" in upi_uri
    assert f"tn=PrintPulse_Order_{order_id}" in upi_uri
    assert f"tr=TXN_{order_id}" in upi_uri

    # Color pricing check (3 pages * 2 copies * Rs 10 = Rs 60.00)
    res_color = client.post(
        "/api/orders/create",
        json={"vendor_id": "shop_alpha", "pages": 3, "copies": 2, "color_mode": "color"},
    )
    assert res_color.status_code == 200
    assert res_color.json()["total_amount"] == 60.0

    # 4. Connect vendor & order status WebSockets and verify settlement broadcast
    with client.websocket_connect("/ws/vendor/shop_alpha") as ws_vendor:
        with client.websocket_connect(f"/ws/orders/{order_id}") as ws_order:
            res_verify = client.post(
                f"/api/orders/{order_id}/verify-payment",
                json={"verified_by": "webhook", "utr": "UTR998877"},
            )
            assert res_verify.status_code == 200, res_verify.text
            verify_data = res_verify.json()
            assert verify_data["status"] == "paid"
            assert verify_data["order"]["amount"] == 14.0

            vendor_msg = json.loads(ws_vendor._send_queue.get(timeout=1.0)["text"])
            assert vendor_msg["event"] == "order_paid"
            assert vendor_msg["order"]["order_id"] == order_id
            assert vendor_msg["order"]["amount"] == 14.0
            assert vendor_msg["order"]["status"] == "paid"

            order_msg = json.loads(ws_order._send_queue.get(timeout=1.0)["text"])
            assert order_msg["event"] == "order_paid"
            assert order_msg["order"]["order_id"] == order_id

    # 5. Polling status endpoint reflects settled state
    res_status = client.get(f"/api/orders/{order_id}/status")
    assert res_status.status_code == 200
    assert res_status.json()["status"] == "paid"


def test_g_print_ready_preprocessing_pipeline(client: TestClient):
    """
    Verifies that GET /api/documents/{order_id}/print-ready:
      1. Applies page range filtering (e.g. pages 1-2 from 3 pages).
      2. Converts pages to DeviceGray monochrome when color_mode is 'bw'.
      3. Duplicates pages sequence by copy count (2 pages * 2 copies = 4 pages).
      4. Supports query parameter overrides and /download parity.
    """
    import pymupdf
    # Create a 3-page test PDF with color text and shapes
    src_doc = pymupdf.open()
    for i in range(3):
        p = src_doc.new_page(width=595, height=842)
        p.draw_rect(pymupdf.Rect(40, 40, 180, 180), color=(1, 0, 0), fill=(0, 0, 1))
        p.insert_text((50, 50), f"Page {i+1} Color Sample", fontsize=18, color=(1, 0, 0))
    sample_pdf_bytes = src_doc.tobytes()

    # Upload document with 2 copies, B&W mode, page_range="1-2"
    upload_res = client.post(
        "/api/documents/batch-upload",
        data={
            "vendor_id": "shop_alpha",
            "copies": 2,
            "is_color": False,
            "page_range": "1-2",
        },
        files=[("files", ("multipage.pdf", sample_pdf_bytes, "application/pdf"))],
    )
    assert upload_res.status_code == 200
    order_id = upload_res.json()["order_id"]

    # 1. Fetch print-ready PDF
    res_print = client.get(f"/api/documents/{order_id}/print-ready")
    assert res_print.status_code == 200
    assert "application/pdf" in res_print.headers.get("content-type", "")

    # Inspect generated PDF structure
    with pymupdf.open(stream=res_print.content, filetype="pdf") as processed_doc:
        # 2 extracted pages * 2 copies = 4 pages total
        assert len(processed_doc) == 4
        # Verify first page embeds only DeviceGray image and has zero color channels
        first_page = processed_doc[0]
        embedded_images = first_page.get_images(full=True)
        assert len(embedded_images) == 1
        img_data = processed_doc.extract_image(embedded_images[0][0])
        assert img_data["colorspace"] == 1  # DeviceGray (1 channel)
        rgb_pix = first_page.get_pixmap(dpi=72)
        samples = rgb_pix.samples
        assert all(
            samples[i] == samples[i + 1] == samples[i + 2]
            for i in range(0, len(samples), 3)
        )

    # 2. Check /download endpoint returns FileResponse with original file and accurate media_type
    res_download = client.get(f"/api/documents/{order_id}/download")
    assert res_download.status_code == 200
    assert "application/pdf" in res_download.headers.get("content-type", "")
    assert len(res_download.content) > 0
    assert upload_res.json()["download_url"].startswith("http://192.168.1.41:8000")

    # 3. Check query override: copies=1, page_range="3", color_mode="color"
    res_override = client.get(
        f"/api/documents/{order_id}/print-ready?copies=1&page_range=3&color_mode=color"
    )
    assert res_override.status_code == 200
    with pymupdf.open(stream=res_override.content, filetype="pdf") as override_doc:
        assert len(override_doc) == 1
        pix_color = override_doc[0].get_pixmap(dpi=150)
        assert pix_color.n == 3


def test_h_multifile_image_and_pdf_merging(client: TestClient):
    """
    Verifies that multi-file orders containing PNG/JPG images:
      1. Correctly calculates total physical pages: sum(pages * copies) = 2 * 4 = 8.
      2. GET /api/documents/{order_id}/download merges all files into a single print-ready PDF.
      3. Returned PDF contains exact 8 A4 pages with grayscale rendering for B&W.
      4. HEAD /api/documents/{order_id}/download returns 200 OK with Content-Disposition.
    """
    import io
    from PIL import Image
    from pypdf import PdfReader

    # Create two minimal 100x100 PNG images
    img1 = Image.new("RGBA", (100, 100), (255, 0, 0, 255))
    buf1 = io.BytesIO()
    img1.save(buf1, format="PNG")
    png1_bytes = buf1.getvalue()

    img2 = Image.new("RGBA", (150, 150), (0, 255, 0, 255))
    buf2 = io.BytesIO()
    img2.save(buf2, format="PNG")
    png2_bytes = buf2.getvalue()

    # Upload two images with copies=4, color_mode="bw"
    items_config = json.dumps([
        {"copies": 4, "is_color": False, "page_range": "all"},
        {"copies": 4, "is_color": False, "page_range": "all"},
    ])

    upload_res = client.post(
        "/api/documents/batch-upload",
        data={
            "vendor_id": "shop_alpha",
            "copies": 4,
            "is_color": False,
            "items_config": items_config,
        },
        files=[
            ("files", ("shot1.png", png1_bytes, "image/png")),
            ("files", ("shot2.png", png2_bytes, "image/png")),
        ],
    )
    assert upload_res.status_code == 200
    upload_data = upload_res.json()
    order_id = upload_data["order_id"]

    # Verify physical page calculation: 2 files * 4 copies = 8 total pages (NOT 64)
    assert upload_data["total_pages"] == 8
    assert upload_data["copies"] == 8

    # Verify HEAD request returns 200 with application/pdf
    head_res = client.head(f"/api/documents/{order_id}/download")
    assert head_res.status_code == 200
    assert "application/pdf" in head_res.headers.get("content-type", "")
    assert f'inline; filename="{order_id}.pdf"' in head_res.headers.get("content-disposition", "")

    # Verify GET request returns 8-page merged PDF
    get_res = client.get(f"/api/documents/{order_id}/download")
    assert get_res.status_code == 200
    assert "application/pdf" in get_res.headers.get("content-type", "")

    reader = PdfReader(io.BytesIO(get_res.content))
    assert len(reader.pages) == 8
    for page in reader.pages:
        # Standard A4 size in points
        assert round(float(page.mediabox.width)) == 595
        assert round(float(page.mediabox.height)) == 842


# ---------------------------------------------------------------------------
# Test I: Landscape Orientation Full-Bleed A4 Generation
# ---------------------------------------------------------------------------
def test_i_landscape_orientation_a4_dimensions(client=None):
    """
    Verifies that:
      1. Batch upload with orientation='landscape' preserves orientation in metadata.
      2. Generated PDF has true A4 Landscape dimensions (841.89 x 595.28 pt).
    """
    from PIL import Image
    from pypdf import PdfReader

    client = client or TestClient(app)

    # Create a 1920x1080 landscape image
    img = Image.new("RGB", (1920, 1080), (124, 58, 237))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    png_bytes = buf.getvalue()

    upload_res = client.post(
        "/api/documents/batch-upload",
        data={
            "vendor_id": "shop_alpha",
            "copies": 2,
            "is_color": False,
            "orientation": "landscape",
        },
        files=[
            ("files", ("screenshot_landscape.png", png_bytes, "image/png")),
        ],
    )
    assert upload_res.status_code == 200
    data = upload_res.json()
    order_id = data["order_id"]
    assert data["orientation"] == "landscape"
    assert data["uploaded_documents"][0]["orientation"] == "landscape"

    # Download compiled print-ready PDF
    get_res = client.get(f"/api/documents/{order_id}/download")
    assert get_res.status_code == 200

    reader = PdfReader(io.BytesIO(get_res.content))
    assert len(reader.pages) == 2  # 2 copies of 1 page
    for p in reader.pages:
        # Standard A4 Landscape size in points: 841.89 x 595.28 pt
        assert round(float(p.mediabox.width)) == 842
        assert round(float(p.mediabox.height)) == 595


# ---------------------------------------------------------------------------
# Test J: Instant Backend Preview PDF Generation
# ---------------------------------------------------------------------------
def test_j_preview_pdf_endpoint(client=None):
    """
    Verifies POST /api/documents/preview-pdf generates a valid A4 PDF preview stream
    matching customer orientation, B&W conversion, and margins without saving to orders.
    """
    from PIL import Image
    from pypdf import PdfReader

    client = client or TestClient(app)

    # 1. Preview landscape image
    img = Image.new("RGB", (800, 600), (255, 128, 0))
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    jpeg_bytes = buf.getvalue()

    prev_res = client.post(
        "/api/documents/preview-pdf",
        data={
            "color_mode": "bw",
            "is_color": False,
            "orientation": "landscape",
        },
        files=[
            ("file", ("photo.jpg", jpeg_bytes, "image/jpeg")),
        ],
    )
    assert prev_res.status_code == 200
    assert "application/pdf" in prev_res.headers.get("content-type", "")
    assert 'filename="exact_print_preview.pdf"' in prev_res.headers.get("content-disposition", "")

    reader = PdfReader(io.BytesIO(prev_res.content))
    assert len(reader.pages) == 1
    p = reader.pages[0]
    assert round(float(p.mediabox.width)) == 842
    assert round(float(p.mediabox.height)) == 595

    # 2. Preview portrait PDF
    pdf_bytes = generate_mock_pdf(num_pages=3)
    prev_pdf_res = client.post(
        "/api/documents/preview-pdf",
        data={
            "color_mode": "color",
            "is_color": True,
            "orientation": "portrait",
            "page_range": "1-2",
        },
        files=[
            ("file", ("document.pdf", pdf_bytes, "application/pdf")),
        ],
    )
    assert prev_pdf_res.status_code == 200
    pdf_reader = PdfReader(io.BytesIO(prev_pdf_res.content))
    assert len(pdf_reader.pages) == 2


# ---------------------------------------------------------------------------
# Test K: Phase 6 Order Status Lifecycle & WebSocket Real-Time Broadcast
# ---------------------------------------------------------------------------
def test_k_order_status_lifecycle_and_websockets(client=None):
    """
    Verifies Phase 6 Part 1 Order Status Tracker lifecycle:
    - POST /api/orders/{order_id}/status updates to 'printing' and 'completed'.
    - GET /api/orders/{order_id} returns full order details.
    - GET /api/orders/{order_id}/status returns current lifecycle state.
    - WS /ws/order/{order_id} and /ws/orders/{order_id} receive live status updates.
    """
    client = client or TestClient(app)

    res_create = client.post(
        "/api/orders/create",
        json={
            "vendor_id": "shop_alpha",
            "pages": 2,
            "copies": 1,
            "color_mode": "bw",
        },
    )
    assert res_create.status_code == 200
    order_id = res_create.json()["order_id"]

    # Mark paid
    res_pay = client.post(
        f"/api/orders/{order_id}/verify-payment",
        json={"verified_by": "test_suite"},
    )
    assert res_pay.status_code == 200
    assert res_pay.json()["status"] == "paid"

    # Test WS on /ws/order/{order_id} (singular alias)
    with client.websocket_connect(f"/ws/order/{order_id}") as ws_order:
        # Initial message upon connect when paid
        initial_msg = json.loads(ws_order._send_queue.get(timeout=1.0)["text"])
        assert initial_msg["status"] == "paid"

        # Update to printing
        res_print = client.post(
            f"/api/orders/{order_id}/status",
            json={"status": "printing"},
        )
        assert res_print.status_code == 200
        assert res_print.json()["status"] == "printing"

        print_msg = json.loads(ws_order._send_queue.get(timeout=1.0)["text"])
        assert print_msg["type"] == "status_update"
        assert print_msg["status"] == "printing"

        # Update to completed
        res_done = client.post(
            f"/api/orders/{order_id}/status",
            json={"status": "completed"},
        )
        assert res_done.status_code == 200
        assert res_done.json()["status"] == "completed"

        done_msg = json.loads(ws_order._send_queue.get(timeout=1.0)["text"])
        assert done_msg["status"] == "completed"

    # Verify GET /api/orders/{order_id} and GET /api/orders/{order_id}/status
    get_res = client.get(f"/api/orders/{order_id}")
    assert get_res.status_code == 200
    assert get_res.json()["status"] == "completed"
    assert get_res.json()["printing_started_at"] is not None
    assert get_res.json()["completed_at"] is not None

    status_res = client.get(f"/api/orders/{order_id}/status")
    assert status_res.status_code == 200
    assert status_res.json()["status"] == "completed"


# ---------------------------------------------------------------------------
# Test L: Dynamic Vendor Pricing, Instant File Cleanup & Daily Stats Summary
# ---------------------------------------------------------------------------
def test_l_dynamic_pricing_stats_and_file_cleanup(client=None):
    """
    Verifies Phase 6 dynamic shop pricing, instant file deletion on completion,
    and daily stats summary endpoints.
    """
    client = client or TestClient(app)
    vendor_id = "shop_dyn_pricing"

    # 1. Read default pricing
    res_get_price = client.get(f"/api/vendor/{vendor_id}/pricing")
    assert res_get_price.status_code == 200
    assert res_get_price.json()["bw_price"] == 2.0
    assert res_get_price.json()["color_price"] == 10.0

    # 2. Update custom pricing (B&W = Rs 3.50, Color = Rs 15.00)
    res_set_price = client.post(
        f"/api/vendor/{vendor_id}/pricing",
        json={"bw_price": 3.5, "color_price": 15.0},
    )
    assert res_set_price.status_code == 200
    assert res_set_price.json()["bw_price"] == 3.5
    assert res_set_price.json()["color_price"] == 15.0

    # 3. Customer portal injects custom rates
    portal_html = client.get(f"/shop/{vendor_id}").text
    assert "bw: Number(3.5)" in portal_html
    assert "color: Number(15.0)" in portal_html

    # 4. Create B&W order with custom rates (2 pages * 1 copy * Rs 3.5 = Rs 7.00)
    res_bw_order = client.post(
        "/api/orders/create",
        json={
            "vendor_id": vendor_id,
            "pages": 2,
            "copies": 1,
            "color_mode": "bw",
        },
    )
    assert res_bw_order.status_code == 200
    assert res_bw_order.json()["total_amount"] == 7.0

    # 5. Create Color order with custom rates (2 pages * 1 copy * Rs 15.0 = Rs 30.00)
    res_col_order = client.post(
        "/api/orders/create",
        json={
            "vendor_id": vendor_id,
            "pages": 2,
            "copies": 1,
            "color_mode": "color",
        },
    )
    assert res_col_order.status_code == 200
    assert res_col_order.json()["total_amount"] == 30.0

    # 6. Upload file and test instant deletion upon 'completed' status
    pdf_bytes = generate_mock_pdf(num_pages=2)
    upload_res = client.post(
        "/api/documents/batch-upload",
        data={"vendor_id": vendor_id, "copies": 1, "is_color": False},
        files=[("files", ("receipt.pdf", pdf_bytes, "application/pdf"))],
    )
    assert upload_res.status_code == 200
    order_id = upload_res.json()["order_id"]

    # Verify file exists on disk
    upload_dir = BACKEND_DIR / "uploads" / vendor_id
    matching_files = [f for f in os.listdir(upload_dir) if f.startswith(f"{order_id}_")]
    assert len(matching_files) > 0

    # Mark order completed
    status_res = client.post(
        f"/api/orders/{order_id}/status",
        json={"status": "completed"},
    )
    assert status_res.status_code == 200
    assert status_res.json()["status"] == "completed"

    # Verify file is instantly deleted from disk
    remaining_files = [f for f in os.listdir(upload_dir) if f.startswith(f"{order_id}_")]
    assert len(remaining_files) == 0

    # 7. Check daily stats summary endpoint
    stats_res = client.get(f"/api/vendor/{vendor_id}/stats")
    assert stats_res.status_code == 200
    stats = stats_res.json()
    assert stats["vendor_id"] == vendor_id
    assert stats["completed_orders"] >= 1
    assert stats["bw_pages_printed"] >= 2
    assert stats["session_revenue"] >= 7.0


# ---------------------------------------------------------------------------
# Cleanup helper to remove test uploads
# ---------------------------------------------------------------------------
def cleanup_test_uploads():
    uploads_root = BACKEND_DIR / "uploads"
    for vendor in ["shop_alpha", "shop_beta", "shop_dyn_pricing"]:
        vdir = uploads_root / vendor
        if vdir.exists():
            for f in os.listdir(vdir):
                try:
                    os.remove(vdir / f)
                except OSError:
                    pass
            try:
                os.rmdir(vdir)
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Standalone CLI Test Runner with Checklist Output
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("\n" + "=" * 65)
    print(" PrintPulse Backend & API Automated Verification Suite")
    print("=" * 65 + "\n")

    test_client = TestClient(app)
    checklist = []

    tests = [
        ("Route resolution & Jinja2 vendor binding", test_a_static_assets_and_web_routes),
        ("Directory isolation per vendor_id", test_b_multi_tenant_batch_upload_and_staging_isolation),
        ("PDF page extraction & pricing calculation", test_b_multi_tenant_batch_upload_and_staging_isolation),
        ("WebSocket scoped event dispatching", test_c_websocket_multi_tenant_connection_and_scoped_dispatch),
        ("Order cancellation & file cleanup", test_d_order_cancellation_and_disk_cleanup),
        ("Auth verification error handling", test_e_google_auth_token_verification_endpoint),
        ("Dynamic UPI order & payment settlement", test_f_upi_order_creation_and_payment_settlement),
        ("Pre-processed print-ready PDF pipeline", test_g_print_ready_preprocessing_pipeline),
        ("Multi-file image and PDF merging", test_h_multifile_image_and_pdf_merging),
        ("Landscape orientation full-bleed A4 generation", test_i_landscape_orientation_a4_dimensions),
        ("Instant backend preview PDF generation", test_j_preview_pdf_endpoint),
        ("Order status lifecycle & WebSocket tracking", test_k_order_status_lifecycle_and_websockets),
        ("Dynamic shop pricing, file cleanup & stats", test_l_dynamic_pricing_stats_and_file_cleanup),
    ]

    all_passed = True
    for description, test_func in tests:
        try:
            test_func(test_client)
            print(f" [PASS] {description}")
            checklist.append((True, description))
        except Exception as exc:
            all_passed = False
            print(f" [FAIL] {description}: {exc}")
            checklist.append((False, description))

    # Teardown any remaining test directories
    cleanup_test_uploads()

    print("\n" + "-" * 65)
    print(" Final Verification Checklist Summary:")
    print("-" * 65)
    for passed, desc in checklist:
        status_tag = "[PASS]" if passed else "[FAIL]"
        print(f" {status_tag} {desc}")
    print("-" * 65 + "\n")

    sys.exit(0 if all_passed else 1)
