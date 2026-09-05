#!/usr/bin/env bash
#
# cam-detect.sh — probe the attached UVC device and print a go2rtc source line.
#
# The Arkmicro CVBS/S-Video dongle (18ec:5850) shows up as a standard UVC
# V4L2 device. Depending on model/firmware it exposes either:
#   * MJPEG @ 720x576 (PAL) or 720x480 (NTSC)   <- compressed, zero-CPU passthrough
#   * raw YUYV                                     <- must be encoded (more CPU)
#
# go2rtc itself also enumerates devices at WebUI > Add > ffmpeg. This script is
# a convenience that prints the exact source line to paste / substitute.
#
# Usage:
#   sudo ./cam-detect.sh            # auto (default): serve native format, zero CPU
#   sudo ./cam-detect.sh passthrough # same as auto (native compressed if possible)
#   sudo ./cam-detect.sh h264        # force software H.264 re-encode (high CPU)
#   sudo ./cam-detect.sh raw         # force raw YUYV source (+ H.264 encode)
#
set -euo pipefail

DEV="${VIDEO_DEVICE:-/dev/video0}"
MODE="${1:-auto}"     # auto | passthrough | h264 | raw

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
# Track the largest size per category so we can prefer a compressed format.
best="";      best_area=0;  best_fmt=""
best_raw="";  best_raw_area=0; best_raw_fmt=""
while IFS= read -r line; do
  fmt=$(printf '%s' "$line" | sed -nE 's/^.*\] (Compressed|Raw) *: +([A-Za-z0-9_]+) : .*/\2/p')
  [ -z "$fmt" ] && continue
  kind=$(printf '%s' "$line" | sed -nE 's/^.*\] (Compressed|Raw) *: .*/\1/p')
  for size in $(printf '%s' "$line" | sed -nE 's/^.*\] (Compressed|Raw) *: +([A-Za-z0-9_]+) : .* : (.*)$/\3/p'); do
    case "$size" in
      [0-9]*x[0-9]*)
        w="${size%x*}"; h="${size#*x}"
        area=$((w*h))
        if [ "$area" -gt "$best_area" ]; then
          best_area=$area; best_fmt=$fmt; best="$size"
        fi
        if [ "$kind" = "Raw" ] && [ "$area" -gt "$best_raw_area" ]; then
          best_raw_area=$area; best_raw_fmt=$fmt; best_raw="$size"
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

# ---------------------------------------------------------------------------
# Select input format + encode strategy.
#   auto/passthrough : serve the device's native compressed stream (H.264/MJPEG)
#                      with NO re-encode. This is what go2rtc itself does for
#                      "compressed" UVC devices, and it keeps CPU ~idle. Raw-only
#                      devices still fall back to a software H.264 encode.
#   h264             : always produce H.264 (software x264) for a classic <video>
#                      MSE stream. High CPU on the Zero 2 W — use only if you
#                      need minimal bandwidth and can accept the load.
case "$MODE" in
  raw)
    FMT="${best_raw_fmt:-$best_fmt}"
    SIZE="${best_raw:-$best}"
    TRANSCODE="#video=h264"           # raw must be encoded for the browser
    ;;
  h264)
    FMT="$best_fmt"; SIZE="$best"
    case "$FMT" in
      h264) TRANSCODE="" ;;           # already H.264, serve directly
      *)    TRANSCODE="#video=h264" ;; # re-encode MJPEG/raw -> H.264 (CPU heavy)
    esac
    ;;
  auto|passthrough)
    FMT="$best_fmt"; SIZE="$best"
    case "$FMT" in
      h264|mjpeg) TRANSCODE="" ;;     # native compressed -> passthrough, zero CPU
      *)          TRANSCODE="#video=h264" ;; # raw-only device -> must encode
    esac
    ;;
  *) echo "unknown mode: $MODE" >&2; exit 1 ;;
esac

# Build the go2rtc ffmpeg-device source line.
# go2rtc maps device inputs itself via internal/ffmpeg/device:
#   -f v4l2 -input_format $FMT -video_size $SIZE -i $DEV
SRC="ffmpeg:device?video=$DEV&input_format=$FMT&video_size=$SIZE${TRANSCODE}"

echo
echo "== recommended go2rtc source =="
echo "$SRC"
if [ -n "$TRANSCODE" ]; then
  echo "   (note: re-encodes to H.264 — will use significant CPU on the Zero 2 W)"
else
  echo "   (native passthrough — near-zero CPU)"
fi
echo
echo "Paste the line above into streams.camera in go2rtc.yaml (or run install.sh)."
echo "Play it later at:  http://<pi>:1984/stream.html?src=camera"
