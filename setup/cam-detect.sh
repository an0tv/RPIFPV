#!/usr/bin/env bash
#
# cam-detect.sh — probe the attached UVC device and print a go2rtc source line.
#
# The Arkmicro CVBS/S-Video dongle (18ec:5850) shows up as a standard UVC
# V4L2 device. Depending on model/firmware it exposes either:
#   * MJPEG @ 720x576 (PAL) or 720x480 (NTSC)   <- zero-encode passthrough
#   * raw YUYV                                     <- go2rtc can still serve it
#
# go2rtc itself also enumerates devices at WebUI > Add > ffmpeg. This script is
# a convenience that prints the exact source line to paste / substitute.
#
# Usage:
#   sudo ./cam-detect.sh            # auto: re-encode to H.264 for a <video> stream
#   sudo ./cam-detect.sh passthrough # zero-CPU: serve the device's native format
#   sudo ./cam-detect.sh raw        # same as auto (software H.264)
#
set -euo pipefail

DEV="${VIDEO_DEVICE:-/dev/video0}"
MODE="${1:-auto}"     # auto | passthrough | raw

if [ ! -c "$DEV" ]; then
  echo "error: $DEV does not exist. Is the USB dongle plugged in?" >&2
  exit 1
fi

echo "== v4l2 device =="
v4l2-ctl -d "$DEV" --info 2>/dev/null || true
echo

# ---------------------------------------------------------------------------
# List formats/resolutions. v4l2-ctl format lines look like:
#   Index : 0  Pixel Format: 'MJPG' (compressed)  Name : Motion-JPEG
#       Size: Discrete 720x576  Interval: Discrete 0.040s (25.000 fps)
echo "== supported formats =="
if command -v v4l2-ctl >/dev/null 2>&1; then
  v4l2-ctl -d "$DEV" --list-formats-ext 2>/dev/null || true
else
  echo "(v4l-utils not installed; install with:  sudo apt install v4l-utils)"
fi

# ---------------------------------------------------------------------------
# go2rtc / ffmpeg format lines look like:
#   [video4linux2,v4l2 @ 0x204e1c0] Compressed:       mjpeg : Motion-JPEG : 640x360 1280x720 ...
#   [video4linux2,v4l2 @ 0x204e1c0] Raw       :     yuyv422 : YUYV 4:2:2 : 640x360 1280x720 ...
# Pick the largest advertised size overall, remembering its pixel format.
#   $best_fmt = codec  $best = WxH
best=""; best_area=0; best_fmt=""
while IFS= read -r line; do
  fmt=$(printf '%s' "$line" | sed -nE 's/^.*\] (Compressed|Raw) *: +([A-Za-z0-9_]+) : .*/\2/p')
  [ -z "$fmt" ] && continue
  for size in $(printf '%s' "$line" | sed -nE 's/^.*\] (Compressed|Raw) *: +([A-Za-z0-9_]+) : .* : (.*)$/\3/p'); do
    case "$size" in
      [0-9]*x[0-9]*)
        w="${size%x*}"; h="${size#*x}"
        area=$((w*h))
        if [ "$area" -gt "$best_area" ]; then
          best_area=$area; best_fmt=$fmt; best="$size"
        fi
        ;;
    esac
  done
done < <(ffmpeg -hide_banner -f v4l2 -list_formats all -i "$DEV" 2>&1 || true)

if [ -z "$best" ]; then
  echo "error: could not enumerate a format for $DEV" >&2
  echo "(try: ffmpeg -hide_banner -f v4l2 -list_formats all -i $DEV)" >&2
  exit 1
fi

case "$MODE" in
  raw|passthrough|auto)
    FMT="$best_fmt"
    ;;
  *) echo "unknown mode: $MODE" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Decide encode strategy.
#   passthrough : zero-CPU. Serve the device's native format verbatim. Best if
#                 the device already emits H.264 or MJPEG; MJPEG still works in
#                 the go2rtc player but consumes more bandwidth per viewer.
#   auto / raw  : re-encode everything to H.264 (software x264). Heavier on the
#                 Zero 2 W, but gives a dependable browser MSE/WebRTC <video>.
if [ "$MODE" = "passthrough" ]; then
  case "$FMT" in
    h264)  TRANSCODE="" ;;
    mjpeg) TRANSCODE="" ;;
    *)     TRANSCODE="#video=h264" ;;  # raw must be encoded
  esac
else
  # browser MSE/WebRTC needs H264; software encode it
  case "$FMT" in
    h264)  TRANSCODE="" ;;   # already H264 - serve directly, zero CPU
    *)     TRANSCODE="#video=h264" ;;
  esac
fi

# Build the go2rtc ffmpeg-device source line.
# go2rtc maps device inputs itself via internal/ffmpeg/device:
#   -f v4l2 -input_format $FMT -video_size $best -i $DEV
SRC="ffmpeg:device?video=$DEV&input_format=$FMT&video_size=$best${TRANSCODE}"

echo
echo "== recommended go2rtc source =="
echo "$SRC"
echo
echo "Paste the line above into streams.camera in go2rtc.yaml (or run install.sh)."
echo "Play it later at:  http://<pi>:1984/stream.html?src=camera"
