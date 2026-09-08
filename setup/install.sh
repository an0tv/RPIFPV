#!/usr/bin/env bash
#
# install.sh — one-shot installer for the PiCam Pi Zero 2 W.
#
# Purpose: show the USB camera fullscreen on the attached screen, on boot.
# No desktop, no web server — just mpv reading the UVC device directly and
# rendering via DRM/KMS.
#
#   sudo bash setup/install.sh
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo/root"; exit 1; fi
die() { echo "ERROR: $*" >&2; exit 1; }

INSTALL_DIR="${INSTALL_DIR:-/opt/picam}"
VIDEO_DEVICE="${VIDEO_DEVICE:-/dev/video0}"
VIDEO_SIZE="${VIDEO_SIZE:-640x480}"
VIDEO_FPS="${VIDEO_FPS:-30}"

echo "==> installing packages (mpv + hardware GL driver)"
export DEBIAN_FRONTEND=noninteractive
apt-get update
# mpv: renders the camera fullscreen.
# libgl1-mesa-dri / libegl-mesa0 / libgbm1: the v3d GPU driver so mpv uses the
#   VideoCore IV hardware instead of software rendering (avoids the lag).
apt-get install -y --no-install-recommends \
  mpv libgl1-mesa-dri libegl-mesa0 libgbm1

echo "==> installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp "$(dirname "$0")/display/display.sh" "$INSTALL_DIR/display.sh"
chmod +x "$INSTALL_DIR/display.sh"

echo "==> installing systemd unit"
sed \
  -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" \
  -e "s|@VIDEO_DEVICE@|$VIDEO_DEVICE|g" \
  -e "s|@VIDEO_SIZE@|$VIDEO_SIZE|g" \
  -e "s|@VIDEO_FPS@|$VIDEO_FPS|g" \
  "$(dirname "$0")/systemd/picam-display.service" \
  > /etc/systemd/system/picam-display.service
systemctl daemon-reload
systemctl enable picam-display.service

echo
echo "==> done. Starting the display now..."
systemctl restart picam-display.service
echo
echo "    The camera feed should now fill the screen."
echo "    It starts automatically on every boot."
echo
echo "    To adjust resolution/framerate, edit:"
echo "      /etc/systemd/system/picam-display.service"
echo "    and run: sudo systemctl daemon-reload && sudo systemctl restart picam-display"
