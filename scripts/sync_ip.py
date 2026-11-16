#!/usr/bin/env python3
"""
PrintPulse LAN IP Auto-Sync Utility
Automatically detects the developer machine's active local Wi-Fi / Ethernet IP
and synchronizes it across:
1. vendor-app/lib/config/api_config.dart (Flutter app host config)
2. backend/.env (Backend environment overrides, if present)

Usage:
  python3 scripts/sync_ip.py          # Auto-detect and sync active LAN IP
  python3 scripts/sync_ip.py <ip>     # Force a specific IP (e.g. 192.168.1.50)
  python3 scripts/sync_ip.py --check  # Check current IP without writing
"""

import os
import re
import socket
import subprocess
import sys

DEFAULT_FALLBACK_IP = "jh0yc.aiccloud.online"
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
API_CONFIG_PATH = os.path.join(
    REPO_ROOT, "vendor-app", "lib", "config", "api_config.dart"
)
BACKEND_ENV_PATH = os.path.join(REPO_ROOT, "backend", ".env")


def detect_active_lan_ip() -> str:
    """Detects active host machine LAN IPv4 address."""
    # 1. Routing table lookup via dummy UDP connect
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        if ip and not ip.startswith("127."):
            return ip
    except Exception:
        pass

    # 2. macOS ipconfig interface interrogation
    for iface in ("en0", "en1", "wlan0", "eth0"):
        try:
            out = subprocess.check_output(
                ["ipconfig", "getifaddr", iface],
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=1,
            ).strip()
            if out and not out.startswith("127."):
                return out
        except Exception:
            pass

    # 3. Hostname resolution
    try:
        host_ip = socket.gethostbyname(socket.gethostname())
        if host_ip and not host_ip.startswith("127."):
            return host_ip
    except Exception:
        pass

    return DEFAULT_FALLBACK_IP


def update_api_config(target_ip: str) -> bool:
    """Updates host IP in api_config.dart."""
    if not os.path.isfile(API_CONFIG_PATH):
        print(f"Warning: {API_CONFIG_PATH} not found.")
        return False

    with open(API_CONFIG_PATH, "r", encoding="utf-8") as f:
        content = f.read()

    # Match static const String defaultHostIp = '...'; OR static const String hostIp = '...';
    pattern = re.compile(
        r"(static\s+const\s+String\s+(?:defaultHostIp|hostIp)\s*=\s*')[^']+(';)"
    )

    if not pattern.search(content):
        # Fallback to any 192.168.x.x string on hostIp
        pattern = re.compile(r"(hostIp\s*=\s*')[^']+(';)")

    new_content, count = pattern.subn(rf"\g<1>{target_ip}\g<2>", content)

    if count > 0 and new_content != content:
        with open(API_CONFIG_PATH, "w", encoding="utf-8") as f:
            f.write(new_content)
        return True
    return False


def update_env_file(target_ip: str) -> bool:
    """Updates or creates backend/.env with dynamic IP."""
    lines = []
    if os.path.isfile(BACKEND_ENV_PATH):
        with open(BACKEND_ENV_PATH, "r", encoding="utf-8") as f:
            lines = f.readlines()

    is_domain = not all(p.isdigit() for p in target_ip.split(".")) if "." in target_ip else False
    protocol = "https" if is_domain else "http"
    port_suffix = "" if is_domain else ":8000"
    base_url = f"{protocol}://{target_ip}{port_suffix}"

    updated_host = False
    updated_url = False
    new_lines = []

    for line in lines:
        if line.startswith("HOST_IP="):
            new_lines.append(f"HOST_IP={target_ip}\n")
            updated_host = True
        elif line.startswith("SHOP_BASE_URL="):
            new_lines.append(f"SHOP_BASE_URL={base_url}\n")
            updated_url = True
        else:
            new_lines.append(line)

    if not updated_host:
        new_lines.append(f"HOST_IP={target_ip}\n")
    if not updated_url:
        new_lines.append(f"SHOP_BASE_URL={base_url}\n")

    with open(BACKEND_ENV_PATH, "w", encoding="utf-8") as f:
        f.writelines(new_lines)
    return True


def main():
    check_only = "--check" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]

    if args:
        target_ip = args[0].strip()
    else:
        target_ip = detect_active_lan_ip()

    print("\n" + "=" * 60)
    print(" PrintPulse Autonomous LAN IP Synchronizer")
    print("=" * 60)
    print(f" Detected Active LAN IP : {target_ip}")
    is_domain = not all(p.isdigit() for p in target_ip.split(".")) if "." in target_ip else False
    protocol = "https" if is_domain else "http"
    ws_protocol = "wss" if is_domain else "ws"
    port_suffix = "" if is_domain else ":8000"

    print(f" HTTP Base Serving URL  : {protocol}://{target_ip}{port_suffix}")
    print(f" WebSocket Endpoint     : {ws_protocol}://{target_ip}{port_suffix}")
    print(f" Customer Web Portal    : {protocol}://{target_ip}{port_suffix}/shop/<vendor_id>")
    print("-" * 60)

    if check_only:
        print(" Mode: Check only (no files modified).")
        print("=" * 60 + "\n")
        return

    updated_flutter = update_api_config(target_ip)
    update_env_file(target_ip)

    if updated_flutter:
        print(" ✓ Synced vendor-app/lib/config/api_config.dart with active IP.")
    else:
        print(" • api_config.dart is already up to date.")
    print(" ✓ Updated backend/.env environment configuration.")
    print("=" * 60 + "\n")


if __name__ == "__main__":
    main()
