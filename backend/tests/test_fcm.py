import unittest
import json
import asyncio
from unittest.mock import patch, MagicMock
from app.core.fcm import (
    find_service_account_path,
    get_fcm_access_token,
    send_fcm_message,
    trigger_fcm_notification,
)


class TestFCM(unittest.TestCase):
    def test_fcm_missing_credentials_graceful(self):
        """Verify that get_fcm_access_token does not crash when no credentials exist."""
        with patch("app.core.fcm.find_service_account_path", return_value=None):
            with patch.dict("os.environ", {}, clear=True):
                token_info = get_fcm_access_token()
                self.assertIsNone(token_info)

    def test_send_fcm_message_without_credentials(self):
        """Verify that send_fcm_message returns False gracefully when unconfigured."""
        with patch("app.core.fcm.get_fcm_access_token", return_value=None):
            success = asyncio.run(
                send_fcm_message(
                    target="vendor-test",
                    title="Test",
                    body="Test Order",
                    data={"order_id": "123"},
                )
            )
            self.assertFalse(success)

    def test_send_fcm_message_success_mock(self):
        """Verify FCM payload structure and HTTP v1 dispatch."""
        mock_auth = ("mock_access_token_123", "printpulse-abhayv175")
        mock_resp = MagicMock()
        mock_resp.status = 200
        mock_resp.__enter__.return_value = mock_resp

        with patch("app.core.fcm.get_fcm_access_token", return_value=mock_auth):
            with patch("urllib.request.urlopen", return_value=mock_resp) as mock_urlopen:
                with patch.dict("sys.modules", {"httpx": None}):
                    success = asyncio.run(
                        send_fcm_message(
                            target="vendor-abhayv175",
                            title="🚨 New Print Job",
                            body="Order #101",
                            data={"order_id": "ord_101", "total_amount": 25.0},
                        )
                    )
                    self.assertTrue(success)
                    self.assertTrue(mock_urlopen.called)
                    call_req = mock_urlopen.call_args[0][0]
                    payload = json.loads(call_req.data.decode("utf-8"))["message"]
                    self.assertEqual(payload["topic"], "vendor-abhayv175")
                    self.assertEqual(payload["notification"]["title"], "🚨 New Print Job")
                    self.assertEqual(payload["android"]["notification"]["channel_id"], "printpulse_urgent_jobs_v2")
                    self.assertEqual(payload["android"]["notification"]["sound"], "new_job")
                    self.assertEqual(payload["data"]["order_id"], "ord_101")

    def test_trigger_fcm_notification_sync(self):
        """Verify trigger_fcm_notification does not raise errors."""
        with patch("app.core.fcm.send_fcm_message", return_value=True):
            trigger_fcm_notification("abhayv175", "Title", "Body", {"order_id": "123"})


if __name__ == "__main__":
    unittest.main()
