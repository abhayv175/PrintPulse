"""
PrintPulse Network Utilities:
Dynamic LAN IP auto-detection, client-aware base URL resolution,
and lightweight UDP service discovery beacon for local serving.
"""

import json
import logging
import os
import socket
import subprocess
import threading
from typing import Optional
from fastapi import Request

logger = logging.getLogger("printpulse.network")

# Default fallback IP when operating completely offline without network interfaces
DEFAULT_FALLBACK_IP = "192.168.1.41"


def get_lan_ip() -> str:
    """
    Dynamically detects the host machine's primary LAN IPv4 address.
    Checks environment variables first, then queries active outbound sockets,
    macOS/Linux network interfaces, and finally falls back to DEFAULT_FALLBACK_IP.
    """
    env_ip = os.getenv("HOST_IP") or os.getenv("SERVER_IP")
    if env_ip and env_ip.strip():
        return env_ip.strip()

    # 1. Routing table lookup using dummy UDP connect (cross-platform, zero packets sent)
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        if ip and not ip.startswith("127."):
            return ip
    except Exception:
        pass

    # 2. System interface interrogation (macOS ipconfig, en0/en1/wlan0/eth0)
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

    # 3. Hostname socket lookup
    try:
        host_ip = socket.gethostbyname(socket.gethostname())
        if host_ip and not host_ip.startswith("127."):
            return host_ip
    except Exception:
        pass

    return DEFAULT_FALLBACK_IP


def get_base_url(request: Optional[Request] = None, port: int = 8000) -> str:
    """
    Resolves the base HTTP URL for client-facing assets, portal links, and downloads.
    Prioritizes explicit environment config, then incoming HTTP Host header,
    then dynamic LAN IP.
    """
    env_base = os.getenv("API_BASE_URL") or os.getenv("SHOP_BASE_URL")
    if env_base and env_base.strip():
        return env_base.rstrip("/")

    if request is not None:
        try:
            host_header = request.headers.get("host")
            if host_header and host_header.strip() and host_header != "testserver":
                scheme = request.url.scheme or "http"
                return f"{scheme}://{host_header.strip()}".rstrip("/")
        except Exception:
            pass

    return f"http://{get_lan_ip()}:{port}".rstrip("/")


class UdpDiscoveryServer:
    """
    Lightweight background UDP discovery listener on port 8002.
    Allows Flutter mobile devices on the same Wi-Fi to locate the server automatically.
    """

    def __init__(self, port: int = 8002, http_port: int = 8000):
        self.port = port
        self.http_port = http_port
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._sock: Optional[socket.socket] = None

    def start(self) -> None:
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(
            target=self._run, daemon=True, name="UdpDiscoveryServer"
        )
        self._thread.start()

    def _run(self) -> None:
        try:
            self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            self._sock.bind(("", self.port))
            self._sock.settimeout(1.0)
            logger.info("PrintPulse UDP discovery beacon active on port %d", self.port)

            while self._running:
                try:
                    data, addr = self._sock.recvfrom(1024)
                    if b"PRINT_PULSE_DISCOVER" in data:
                        lan_ip = get_lan_ip()
                        response = json.dumps(
                            {
                                "service": "printpulse",
                                "ip": lan_ip,
                                "port": self.http_port,
                                "ws_url": f"ws://{lan_ip}:{self.http_port}",
                                "http_url": f"http://{lan_ip}:{self.http_port}",
                                "status": "ready",
                            }
                        ).encode("utf-8")
                        self._sock.sendto(response, addr)
                except socket.timeout:
                    continue
                except Exception as e:
                    if self._running:
                        logger.debug("UDP discovery loop error: %s", e)
        except Exception as e:
            logger.warning("Could not start UDP discovery listener on port %d: %s", self.port, e)
        finally:
            if self._sock:
                try:
                    self._sock.close()
                except Exception:
                    pass

    def stop(self) -> None:
        self._running = False
        if self._sock:
            try:
                self._sock.close()
            except Exception:
                pass


udp_discovery = UdpDiscoveryServer()
