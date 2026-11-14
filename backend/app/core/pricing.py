from typing import Optional
from urllib.parse import quote
from pydantic import BaseModel

RATE_BW_PER_PAGE: float = 2.00
RATE_COLOR_PER_PAGE: float = 10.00


class PricingCalculation(BaseModel):
    pages: int
    copies: int
    is_color: bool
    rate_per_page: float
    total_amount: float


def compute_order_amount(
    pages: int,
    copies: int,
    is_color: bool,
    bw_rate: Optional[float] = None,
    color_rate: Optional[float] = None,
) -> PricingCalculation:
    if pages < 1:
        raise ValueError("Document must have at least 1 page.")
    if copies < 1:
        raise ValueError("Must request at least 1 copy.")

    bw = float(bw_rate) if bw_rate is not None and bw_rate > 0 else RATE_BW_PER_PAGE
    col = float(color_rate) if color_rate is not None and color_rate > 0 else RATE_COLOR_PER_PAGE

    rate = col if is_color else bw
    total = round(pages * copies * rate, 2)

    return PricingCalculation(
        pages=pages,
        copies=copies,
        is_color=is_color,
        rate_per_page=rate,
        total_amount=total,
    )


def build_upi_uri(
    vendor_vpa: str,
    vendor_name: str,
    total_amount: float,
    order_id: str,
    transaction_ref: str,
) -> str:
    """
    Formats an NPCI-compliant dynamic UPI intent deep-link string.
    Example: upi://pay?pa=shop@okaxis&pn=PrintPulse%20Kiosk&am=14.00&cu=INR&tn=PrintPulse_Order_ord_123&tr=TXN_ord_123
    """
    pa = quote(vendor_vpa.strip(), safe="@._-")
    pn = quote(vendor_name.strip() or "PrintPulse Kiosk", safe="")
    am = f"{total_amount:.2f}"
    tn = quote(f"PrintPulse_Order_{order_id}", safe="_-")
    tr = quote(transaction_ref.strip(), safe="_-")
    return f"upi://pay?pa={pa}&pn={pn}&am={am}&cu=INR&tn={tn}&tr={tr}"