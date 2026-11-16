import os
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from app.api.routes_upload import router as upload_router
from app.api.routes_vendor import router as vendor_router, websocket_vendor, get_vendor_profile
from app.api.routes_auth import router as auth_router
from app.api.routes_orders import router as orders_router, websocket_order_status
from app.core.network import get_lan_ip, get_base_url, udp_discovery


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Lifecycle manager: activates local UDP discovery beacon and logs dynamic network endpoints."""
    lan_ip = get_lan_ip()
    base_url = get_base_url()
    print("\n" + "=" * 62)
    print("  PrintPulse Backend Active")
    print(f"  LAN Serving URL    : {base_url}")
    print(f"  Customer Web Portal: {base_url}/shop/<vendor_id>")
    print("  UDP Discovery Beacon: Listening on port 8002")
    print("=" * 62 + "\n")
    udp_discovery.start()
    try:
        yield
    finally:
        udp_discovery.stop()


app = FastAPI(
    title="PrintPulse API",
    description="Automated Kiosk & Shop Print-on-Demand Backend",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Directories
BASE_DIR = os.path.dirname(__file__)
TEMPLATES_DIR = os.path.join(BASE_DIR, "templates")
STATIC_DIR = os.path.join(BASE_DIR, "static")
UPLOADS_DIR = os.path.join(BASE_DIR, "uploads")
os.makedirs(UPLOADS_DIR, exist_ok=True)

# Mount static & uploads folders
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
app.mount("/uploads", StaticFiles(directory=UPLOADS_DIR), name="uploads")

templates = Jinja2Templates(directory=TEMPLATES_DIR)

# Mount API routes
app.include_router(upload_router, prefix="/api/documents", tags=["Documents"])
app.include_router(vendor_router, prefix="/api/vendor", tags=["Vendor"])
app.include_router(vendor_router, prefix="/api/vendors", tags=["Vendors"])
app.include_router(auth_router, prefix="/api/auth", tags=["Auth"])
app.include_router(auth_router, prefix="/api/vendor/auth", tags=["Vendor Auth"])
app.include_router(orders_router, prefix="/api/orders", tags=["Orders & Payments"])
app.include_router(orders_router, prefix="/api/jobs", tags=["Jobs & Payments"])


@app.post("/api/payments/verify")
async def payments_verify_alias(request: Request):
    """Alias endpoint for payment gateway webhooks or direct verification requests."""
    data = await request.json()
    order_id = data.get("order_id")
    if not order_id:
        from fastapi import HTTPException
        raise HTTPException(status_code=400, detail="Missing order_id")
    from app.api.routes_orders import verify_order_payment, VerifyPaymentRequest
    amount_val = float(data["amount"]) if data.get("amount") is not None else None
    verify_req = VerifyPaymentRequest(
        transaction_ref=data.get("transaction_ref"),
        utr=data.get("utr"),
        verified_by=data.get("verified_by", "webhook"),
        payer_name=data.get("payer_name"),
        payer_vpa=data.get("payer_vpa"),
        amount=amount_val,
    )
    return await verify_order_payment(order_id, verify_req)

# WebSocket direct endpoints for vendor APK live queue and customer payment status
app.add_api_websocket_route("/ws/vendor/{vendor_id}", websocket_vendor)
app.add_api_websocket_route("/ws/{vendor_id}", websocket_vendor)
app.add_api_websocket_route("/ws/orders/{order_id}", websocket_order_status)
app.add_api_websocket_route("/ws/order/{order_id}", websocket_order_status)


# --- Favicon & Apple Touch Icon Handlers ---
@app.get("/favicon.ico", include_in_schema=False)
async def favicon():
    return FileResponse(
        os.path.join(STATIC_DIR, "favicon.ico"), media_type="image/x-icon"
    )


@app.get("/apple-touch-icon.png", include_in_schema=False)
@app.get("/apple-touch-icon-precomposed.png", include_in_schema=False)
async def apple_touch_icon():
    return FileResponse(
        os.path.join(STATIC_DIR, "favicon.svg"), media_type="image/svg+xml"
    )


# --- Customer Portal strictly at /shop/{vendor_id} ---
@app.get("/shop/{vendor_id}", response_class=HTMLResponse)
async def serve_shop_portal(request: Request, vendor_id: str):
    clean_vendor_id = os.path.basename(vendor_id.strip())
    profile = get_vendor_profile(clean_vendor_id)
    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={
            "vendor_id": clean_vendor_id,
            "bw_price": float(profile.get("bw_price", 2.0)),
            "color_price": float(profile.get("color_price", 10.0)),
        },
    )


@app.get("/")
@app.get("/health")
def health_check(request: Request):
    return {
        "status": "ok",
        "service": "printpulse-backend",
        "host_ip": get_lan_ip(),
        "base_url": get_base_url(request),
    }
