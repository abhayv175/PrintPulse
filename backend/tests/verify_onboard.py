import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import json
import httpx
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)

def test_onboard_lifecycle():
    vendor_id = "test_onboard_vendor_1"
    
    # 1. Check initial profile
    res1 = client.get(f"/api/vendor/{vendor_id}/profile")
    assert res1.status_code == 200, f"Get profile failed: {res1.text}"
    prof1 = res1.json()
    print("Initial profile:", prof1)
    assert prof1.get("onboarded") is False
    
    # 2. Call Onboarding PATCH
    onboard_payload = {
        "shop_name": "Test Express Print Hub",
        "vendor_name": "Test Vendor",
        "bw_price": 3.0,
        "color_price": 15.0,
        "upi_id": "expressprint@okaxis"
    }
    res2 = client.patch(f"/api/vendors/{vendor_id}/onboard", json=onboard_payload)
    assert res2.status_code == 200, f"Onboard patch failed: {res2.text}"
    onboard_resp = res2.json()
    print("Onboard response:", onboard_resp)
    assert onboard_resp.get("onboarded") is True
    assert onboard_resp.get("shop_name") == "Test Express Print Hub"
    assert onboard_resp.get("upi_id") == "expressprint@okaxis"
    assert onboard_resp.get("bw_price") == 3.0
    assert onboard_resp.get("color_price") == 15.0
    
    # 3. Check updated profile
    res3 = client.get(f"/api/vendor/{vendor_id}/profile")
    assert res3.status_code == 200
    prof3 = res3.json()
    assert prof3.get("onboarded") is True
    assert prof3.get("shop_name") == "Test Express Print Hub"
    assert prof3.get("upi_id") == "expressprint@okaxis"
    assert prof3.get("bw_price") == 3.0
    assert prof3.get("color_price") == 15.0
    
    # 4. Check web portal /shop/{vendor_id} rendering
    res4 = client.get(f"/shop/{vendor_id}")
    assert res4.status_code == 200
    html = res4.text
    assert "autoDeleteToggle" in html
    assert "autoDeleteSwitchTrack" in html
    assert "Delete document immediately after printing" in html
    print("Web portal verified with auto-delete toggle!")
    
    print("\n[ALL ONBOARDING TESTS PASSED SUCCESSFULLY!]")

if __name__ == "__main__":
    test_onboard_lifecycle()
