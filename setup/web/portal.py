#!/usr/bin/env python3
"""
portal.py — small web UI + config API for the OpenIPC Pi.

Serves on :8080 so it is reachable both on your LAN (STA mode) and on the
fallback AP. Two roles in one origin:
  * `/`            the page (live stream + "join a Wi-Fi network" form)
  * `/api/wifi`    GET current status  |  POST save SSID/password and reconnect
  * `/api/reboot`  POST reboot the Pi

The live stream <iframe> points at go2rtc's own player on :1984
(stream.html?src=camera), which auto-selects WebRTC / MSE for low latency.
"""
import json
import os
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF = "/etc/openipc/wifi.json"
NETD = "/opt/openipc/netd.sh"
ROOT = "/opt/openipc/web"
PORT = int(os.environ.get("PORT", "8080"))
WIFI_IF = os.environ.get("WIFI_IF", "wlan0")
AP_IP = os.environ.get("AP_IP", "10.42.0.1")

def read_conf():
    try:
        with open(CONF) as f:
            return json.load(f)
    except Exception:
        return {}

def write_conf(cfg):
    # restrict permissions: contains a Wi-Fi password
    fd = os.open(CONF, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(CONF, 0o600)

def wifi_status():
    """Best-effort snapshot: are we a client, and of which network?"""
    out = {}
    try:
        # connected ssid of wlan0
        r = subprocess.run(
            ["nmcli", "-t", "-f", "active,ssid", "dev", "wifi", "list"],
            capture_output=True, text=True, timeout=10)
        active = [l.split(":", 1)[1] for l in r.stdout.splitlines()
                  if l.startswith("yes:")]
        out["connected_ssid"] = active[0] if active else ""
        r = subprocess.run(["nmcli", "-t", "-f", "GENERAL.STATE",
                            "device", "show", WIFI_IF],
                           capture_output=True, text=True, timeout=10)
        out["device_state"] = r.stdout.strip().split(":")[-1].strip()
    except Exception:
        pass
    return out

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/api/wifi":
            cfg = read_conf()
            st = wifi_status()
            self._send(200, json.dumps({
                "ssid": cfg.get("ssid", ""),
                "ap_ssid": cfg.get("ap_ssid", "openipc-cam"),
                "mode": "client" if st.get("connected_ssid") else "ap",
                **st,
            }))
        elif self.path == "/":
            p = os.path.join(ROOT, "index.html")
            if os.path.exists(p):
                with open(p, "rb") as f:
                    html = f.read()
                self._send(200, html, "text/html; charset=utf-8")
            else:
                self._send(404, "index.html not found", "text/plain")
        elif self.path == "/health":
            self._send(200, "ok", "text/plain")
        else:
            self._send(404, "not found", "text/plain")

    def do_POST(self):
        ln = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(ln) if ln else b"{}"
        try:
            data = json.loads(raw.decode())
        except Exception:
            data = {}
        if self.path == "/api/wifi":
            ssid = (data.get("ssid") or "").strip()
            password = (data.get("password") or "").strip()
            if not ssid:
                return self._send(400, json.dumps({"error": "ssid required"}))
            cfg = read_conf()
            cfg["ssid"] = ssid
            if password:
                cfg["password"] = password
            write_conf(cfg)
            # re-evaluate role now (tear down AP, try to join). On reboot netd
            # runs anyway, so a failure just brings the AP back.
            try:
                subprocess.Popen(["systemctl", "restart", "openipc-net"],
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
            except Exception:
                pass
            return self._send(200, json.dumps({"ok": True, "ssid": ssid}))
        if self.path == "/api/reboot":
            # small delay so the HTTP response flushes before reboot
            subprocess.Popen(["bash", "-c",
                              "sleep 1 && systemctl reboot"],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
            return self._send(200, json.dumps({"ok": True, "rebooting": True}))
        return self._send(404, json.dumps({"error": "not found"}))

if __name__ == "__main__":
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"portal listening on 0.0.0.0:{PORT}", flush=True)
    srv.serve_forever()
