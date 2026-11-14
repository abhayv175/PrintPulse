import os
from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from app.api.routes_upload import router as upload_router
from app.api.routes_vendor import router as vendor_router, websocket_vendor, get_vendor_profile
from app.api.routes_auth import router as auth_router
from app.api.routes_orders import router as orders_router, websocket_order_status

app = FastAPI(
    title="PrintPulse API",
    description="Automated Kiosk & Shop Print-on-Demand Backend",
    version="1.0.0",
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
app.include_router(auth_router, prefix="/api/vendor/auth", tags=["Vendor Auth"])
app.include_router(orders_router, prefix="/api/orders", tags=["Orders & Payments"])

# WebSocket direct endpoints for vendor APK live queue and customer payment status
app.add_api_websocket_route("/ws/vendor/{vendor_id}", websocket_vendor)
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


@app.get("/health")
def health_check():
    return {"status": "ok", "service": "printpulse-backend"}
