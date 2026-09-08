#!/usr/bin/env bash
#
# display.sh — fullscreen local preview of the USB camera on the attached screen.
#
# Reads the UVC device DIRECTLY (no go2rtc, no web server). mpv renders straight
# to DRM/KMS, so no X11/Wayland desktop is needed on Raspberry Pi OS Lite.
#
# The Arkmicro dongle exposes MJPEG (640x480 and 352x288). We tell libavformat
# to request mjpeg at 640x480 so it doesn't fall back to slow raw YUYV.
#
set -euo pipefail

DEV="${VIDEO_DEVICE:-/dev/video0}"
SIZE="${VIDEO_SIZE:-640x480}"
FPS="${VIDEO_FPS:-30}"
CONNECTOR="${DISPLAY_CONNECTOR:-}"   # e.g. HDMI-A-1 or DSI-1; empty = autodetect

args=(--vo=gpu --gpu-context=drm --fs --no-border --no-osd-bar --really-quiet
      --profile=low-latency --untimed
      --demuxer-lavf-o="video_size=$SIZE,input_format=mjpeg,framerate=$FPS")
if [ -n "$CONNECTOR" ]; then
  args+=(--drm-connector="$CONNECTOR")
fi

# If the device isn't there yet, wait a moment (USB can be slow to enumerate).
for _ in $(seq 1 30); do
  [ -c "$DEV" ] && break
  sleep 1
done
[ -c "$DEV" ] || { echo "error: $DEV not found" >&2; exit 1; }

exec mpv "${args[@]}" "av://v4l2:$DEV"
