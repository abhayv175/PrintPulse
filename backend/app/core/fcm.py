import os
import re
import json
import time
import logging
import asyncio
from typing import Optional, Dict, Any, Tuple

logger = logging.getLogger("fcm")

_cached_token: Optional[str] = None
_token_expiry: float = 0.0
_cached_project_id: Optional[str] = None
_missing_credentials_warned = False


def find_service_account_path() -> Optional[str]:
    """Locates a Firebase/Google Cloud service account JSON file."""
    # 1. Explicit env vars
    for env_var in [
        "FIREBASE_SERVICE_ACCOUNT_KEY",
        "FIREBASE_SERVICE_ACCOUNT_PATH",
        "GOOGLE_APPLICATION_CREDENTIALS",
    ]:
        val = os.getenv(env_var)
        if val and os.path.isfile(val):
            return val

    # 2. Search in backend/ root directory
    base_dir = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for fname in os.listdir(base_dir):
        if fname.endswith(".json") and any(
            k in fname.lower() for k in ["service-account", "firebase", "adminsdk"]
        ):
            candidate = os.path.join(base_dir, fname)
            try:
                with open(candidate, "r") as f:
                    data = json.load(f)
                    if "private_key" in data and "client_email" in data:
                        return candidate
            except Exception:
                continue

    return None


def _get_sa_info(key_path: Optional[str], env_json: Optional[str]) -> Optional[Dict[str, Any]]:
    if key_path and os.path.isfile(key_path):
        try:
            with open(key_path, "r") as f:
                return json.load(f)
        except Exception:
            pass
    if env_json:
        try:
            return json.loads(env_json)
        except Exception:
            pass
    return None


def _generate_jwt_and_fetch_token(sa_dict: Dict[str, Any]) -> Optional[Tuple[str, str, float]]:
    """Generates an OAuth2 token using standard library and openssl without requiring google-auth."""
    import base64
    import tempfile
    import subprocess
    import urllib.request
    import urllib.parse

    client_email = sa_dict.get("client_email")
    private_key = sa_dict.get("private_key")
    project_id = sa_dict.get("project_id", "printpulse-abhayv175")
    if not client_email or not private_key:
        return None

    header = base64.urlsafe_b64encode(json.dumps({"alg": "RS256", "typ": "JWT"}).encode()).rstrip(b"=")
    now = int(time.time())
    claims = {
        "iss": client_email,
        "scope": "https://www.googleapis.com/auth/firebase.messaging",
        "aud": "https://oauth2.googleapis.com/token",
        "exp": now + 3600,
        "iat": now,
    }
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b"=")
    signing_input = header + b"." + payload

    with tempfile.NamedTemporaryFile("w", delete=False) as kf:
        kf.write(private_key)
        kpath = kf.name

    try:
        proc = subprocess.Popen(
            ["openssl", "dgst", "-sha256", "-sign", kpath],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        sig, err = proc.communicate(input=signing_input)
    finally:
        try:
            os.remove(kpath)
        except OSError:
            pass

    if proc.returncode != 0:
        logger.warning(f"FCM: openssl signing failed: {err.decode('utf-8', errors='ignore')}")
        return None

    assertion = (signing_input + b"." + base64.urlsafe_b64encode(sig).rstrip(b"=")).decode("utf-8")
    data = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": assertion,
    }).encode("utf-8")

    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=10.0) as resp:
        res_data = json.loads(resp.read().decode("utf-8"))
        token = res_data.get("access_token")
        expires_in = res_data.get("expires_in", 3600)
        if token:
            return token, project_id, time.time() + float(expires_in)
    return None


def get_fcm_access_token() -> Optional[Tuple[str, str]]:
    """
    Obtains a valid OAuth2 Bearer token with the firebase.messaging scope
    using google-auth (or openssl JWT fallback) and returns (token, project_id).
    Tokens are cached in memory until near expiry.
    """
    global _cached_token, _token_expiry, _cached_project_id, _missing_credentials_warned

    # Return cached token if valid (buffered by 90 seconds)
    if _cached_token and _cached_project_id and time.time() < (_token_expiry - 90):
        return _cached_token, _cached_project_id

    # Check for direct JSON string in env
    env_json = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON")
    key_path = find_service_account_path()

    if not key_path and not env_json:
        if not _missing_credentials_warned:
            logger.info(
                "FCM: No service account JSON found. Push notifications to killed apps will be skipped "
                "until service-account.json is provided in backend/."
            )
            _missing_credentials_warned = True
        return None

    # First attempt: standard google-auth library
    try:
        from google.oauth2 import service_account
        from google.auth.transport.requests import Request

        scopes = ["https://www.googleapis.com/auth/firebase.messaging"]

        if key_path:
            creds = service_account.Credentials.from_service_account_file(
                key_path, scopes=scopes
            )
        else:
            info = json.loads(env_json)
            creds = service_account.Credentials.from_service_account_info(
                info, scopes=scopes
            )

        creds.refresh(Request())
        _cached_token = creds.token
        _token_expiry = (
            creds.expiry.timestamp() if creds.expiry else (time.time() + 3500)
        )
        _cached_project_id = creds.project_id or "printpulse-abhayv175"
        return _cached_token, _cached_project_id
    except Exception as e:
        logger.debug(f"FCM: google-auth failed or unavailable ({e}); trying openssl JWT fallback...")

    # Second attempt: standard library + openssl JWT fallback
    sa_info = _get_sa_info(key_path, env_json)
    if sa_info:
        try:
            token_res = _generate_jwt_and_fetch_token(sa_info)
            if token_res:
                _cached_token, _cached_project_id, _token_expiry = token_res
                return _cached_token, _cached_project_id
        except Exception as e:
            logger.warning(f"FCM: Fallback JWT signing failed: {e}")

    logger.warning("FCM: Failed to obtain OAuth2 access token via both google-auth and fallback.")
    return None


async def send_fcm_message(
    target: str,
    title: str,
    body: str,
    data: Optional[Dict[str, Any]] = None,
    is_topic: bool = True,
) -> bool:
    """
    Sends an FCM HTTP v1 push notification to a topic or device token.
    Configured with high priority, custom 'new_job' sound, and channel 'printpulse_urgent_jobs_v2'
    so Android SystemUI displays a heads-up alert even when the app is killed.
    """
    auth = get_fcm_access_token()
    if not auth:
        return False

    token, project_id = auth

    # Stringify all data payload fields for FCM v1 specification compliance
    sanitized_data: Dict[str, str] = {
        "title": str(title),
        "body": str(body),
        "click_action": "FLUTTER_NOTIFICATION_CLICK",
    }
    if data:
        for k, v in data.items():
            if isinstance(v, (dict, list)):
                sanitized_data[k] = json.dumps(v)
            elif v is not None:
                sanitized_data[k] = str(v)

    message_target = {"topic": target} if is_topic else {"token": target}

    message_payload = {
        "message": {
            **message_target,
            "notification": {
                "title": title,
                "body": body,
            },
            "data": sanitized_data,
            "android": {
                "priority": "HIGH",
                "notification": {
                    "channel_id": "printpulse_urgent_jobs_v2",
                    "sound": "new_job",
                    "default_sound": False,
                    "icon": "ic_notification",
                    "notification_priority": "PRIORITY_MAX",
                    "visibility": "PUBLIC",
                },
            },
        }
    }

    url = f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json; UTF-8",
    }

    try:
        try:
            import httpx
            async with httpx.AsyncClient(timeout=8.0) as client:
                resp = await client.post(url, headers=headers, json=message_payload)
                if resp.status_code == 200:
                    logger.info(f"FCM: Successfully sent push notification to {target} (status {resp.status_code})")
                    return True
                else:
                    logger.warning(
                        f"FCM: Google API error {resp.status_code} sending to {target}: {resp.text}"
                    )
                    return False
        except ImportError:
            import urllib.request
            req = urllib.request.Request(
                url,
                data=json.dumps(message_payload).encode("utf-8"),
                headers=headers,
            )
            with urllib.request.urlopen(req, timeout=8.0) as resp:
                if resp.status == 200:
                    logger.info(f"FCM: Successfully sent push notification to {target} (status {resp.status})")
                    return True
                return False
    except Exception as e:
        logger.warning(f"FCM: Network error dispatching push notification: {e}")
        return False


def trigger_fcm_notification(
    vendor_id: str,
    title: str,
    body: str,
    data: Optional[Dict[str, Any]] = None,
):
    """
    Non-blocking, fire-and-forget helper that dispatches an FCM push to the vendor's topic.
    """
    if not vendor_id:
        return
    clean = re.sub(r"[^a-zA-Z0-9_-]", "_", vendor_id.strip())
    topic = f"vendor-{clean}"

    try:
        loop = asyncio.get_running_loop()
        loop.create_task(
            send_fcm_message(
                target=topic,
                title=title,
                body=body,
                data=data,
                is_topic=True,
            )
        )
    except RuntimeError:
        # No running event loop (e.g. background thread or test)
        try:
            asyncio.run(
                send_fcm_message(
                    target=topic,
                    title=title,
                    body=body,
                    data=data,
                    is_topic=True,
                )
            )
        except Exception:
            pass
    except Exception as e:
        logger.debug(f"FCM trigger note: {e}")
