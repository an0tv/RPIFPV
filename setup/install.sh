#!/usr/bin/env bash
#
# install.sh — one-shot installer for the PiCam Pi Zero 2 W.
# Run as root ON THE PI after copying this repo over (e.g. /opt/picam).
#
#   sudo bash setup/install.sh
#
# What it does:
#   1. installs packages (go2rtc binary, ffmpeg, v4l-utils, network-manager)
#   2. detects the camera and renders /etc/picam/go2rtc.yaml
#   3. creates user+dirs, default wifi config
#   4. installs systemd units and starts everything
#
set -euo pipefail

# ---- editable -------------------------------------------------------------
INSTALL_DIR="${INSTALL_DIR:-/opt/picam}"
RUN_USER="${RUN_USER:-picam}"
GO2RTC_VERSION="${GO2RTC_VERSION:-latest}"          # or pin e.g. v1.9.13
# ---------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo/root"; exit 1; fi
die() { echo "ERROR: $*" >&2; exit 1; }

echo "==> installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
# dnsmasq-base (NOT dnsmasq): NetworkManager's shared/hotspot mode needs the
# dnsmasq binary, but the full dnsmasq package ships a standalone systemd
# service that would fight NM for the DHCP/DNS port.
# hostapd: NetworkManager needs it to actually host an Access Point.
apt-get install -y --no-install-recommends \
  ffmpeg v4l-utils network-manager hostapd dnsmasq-base ca-certificates curl unzip python3

systemctl enable --now NetworkManager >/dev/null 2>&1 || true

# ---- runtime user ---------------------------------------------------------
echo "==> creating user '$RUN_USER'"
mkdir -p "$INSTALL_DIR"
id "$RUN_USER" >/dev/null 2>&1 || useradd -r -m -d "$INSTALL_DIR" -s /usr/sbin/nologin "$RUN_USER"
usermod -a -G video "$RUN_USER" || true

# ---- layout ---------------------------------------------------------------
echo "==> laying out $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/web" /etc/picam /var/log/picam

cp -r "$(dirname "$0")/web/." "$INSTALL_DIR/web/"
cp "$(dirname "$0")/wifi/netd.sh" "$INSTALL_DIR/netd.sh"
cp "$(dirname "$0")/cam-detect.sh" "$INSTALL_DIR/cam-detect.sh"
chmod +x "$INSTALL_DIR/netd.sh" "$INSTALL_DIR/web/portal.py" "$INSTALL_DIR/cam-detect.sh"
chown -R "$RUN_USER":"$RUN_USER" "$INSTALL_DIR" 2>/dev/null || true

# ---- go2rtc ---------------------------------------------------------------
echo "==> installing go2rtc ($GO2RTC_VERSION)"
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) G2A="go2rtc_linux_arm64" ;;
  armv7l|armhf|armv6l) G2A="go2rtc_linux_arm" ;;
  *) die "unsupported arch: $ARCH" ;;
esac

if [ "$GO2RTC_VERSION" = "latest" ]; then
  URL="https://github.com/AlexxIT/go2rtc/releases/latest/download/$G2A"
else
  URL="https://github.com/AlexxIT/go2rtc/releases/download/$GO2RTC_VERSION/$G2A"
fi
curl -fsSL -o "$INSTALL_DIR/go2rtc" "$URL"
chmod +x "$INSTALL_DIR/go2rtc"

# ---- camera detection & config -------------------------------------------
echo "==> detecting camera"
CAM_SOURCE=""
# Give the OS a moment if the dongle was just attached.
for _ in 1 2 3; do
  CAM_SOURCE="$( "$(dirname "$0")/cam-detect.sh" 2>/dev/null | grep -E '^ffmpeg:device' | head -1 || true )"
  [ -n "$CAM_SOURCE" ] && break
  sleep 1
done
if [ -z "$CAM_SOURCE" ]; then
  echo "WARN: could not detect the UVC camera automatically."
  echo "      /etc/picam/go2rtc.yaml will use a placeholder source."
  echo "      (After plugging the dongle in, re-run /opt/picam/cam-detect.sh.)"
  CAM_SOURCE="ffmpeg:device?video=/dev/video0&input_format=mjpeg&video_size=720x576"
fi

# Render config (heredoc avoids sed-escaping the & and # inside the URL).
mkdir -p /etc/picam
cat > /etc/picam/go2rtc.yaml <<EOF
log:
  level: info
api:
  listen: ":1984"
webrtc:
  listen: ":8555"
rtsp:
  listen: ":8554"
streams:
  camera:
    - "$CAM_SOURCE"
EOF
echo "    source: $CAM_SOURCE"

# ---- default wifi config --------------------------------------------------
if [ ! -f /etc/picam/wifi.json ]; then
  cp "$(dirname "$0")/wifi/wifi.default.json" /etc/picam/wifi.json
fi
chmod 600 /etc/picam/wifi.json

# ---- systemd --------------------------------------------------------------
echo "==> installing systemd units"
cp "$(dirname "$0")/systemd/"*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable picam-net.service picam-camera.service picam-portal.service

echo
echo "==> done. The Wi-Fi supervisor runs in 'auto' mode: it keeps the saved"
echo "    network joined and switches to AP '$(sed -n 's/.*"ap_ssid": *"\([^"]*\)".*/\1/p' /etc/picam/wifi.json || echo picam)'"
echo "    if the link is ever unreachable. Change mode in the web UI (Auto/AP/Wi-Fi)."
echo
echo "    Watch the stream:   http://<pi-ip>:8080   (or on the AP: http://10.42.0.1:8080)"
echo "    Direct player:      http://<pi-ip>:1984/stream.html?src=camera"
echo
echo "    Start services now with:"
echo "      systemctl start picam-net picam-camera picam-portal"
