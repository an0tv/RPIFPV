# PiCam — Raspberry Pi Zero 2 W camera preview

Shows a USB **CVBS/S-Video capture dongle** (Arkmicro `18ec:5850`, a standard UVC
device at `/dev/video0`) **fullscreen on an attached screen**, automatically on
boot. No desktop, no web server — just `mpv` reading the camera directly and
rendering via the GPU (DRM/KMS).

```
USB capture dongle ──► /dev/video0 (MJPEG) ──► mpv (hardware GPU) ──► fullscreen
```

## Requirements

- Raspberry Pi Zero 2 W, Raspberry Pi OS **Lite** (no desktop needed)
- The Arkmicro `18ec:5850` CVBS/S-Video USB capture dongle
- An HDMI (or DSI) screen attached

## Install

```bash
scp -r setup pi@<ip>:~/
ssh pi@<ip>
sudo bash ~/setup/install.sh
```

That's it — the camera feed fills the screen immediately and on every boot.

## What it does

`install.sh` installs:

- **mpv** — renders the video fullscreen.
- **the v3d GPU driver** (`libgl1-mesa-dri` etc.) — so mpv uses the VideoCore IV
  hardware. Without this, mpv falls back to software rendering ("dumb mode") and
  the picture lags.
- **`picam-display.service`** — a systemd unit that runs `display.sh` on boot and
  restarts it if it ever exits.

`display.sh` reads `/dev/video0` directly:

```bash
mpv --vo=gpu --gpu-context=drm --fs \
    --profile=low-latency --cache=no --untimed --framedrop=vo \
    --demuxer-lavf-o=video_size=640x480,input_format=mjpeg,framerate=30 \
    av://v4l2:/dev/video0
```

The camera advertises MJPEG at `640x480` and `352x288`; we request MJPEG at
`640x480` (its largest mode) so it doesn't fall back to slow raw YUYV.

## Configuration

Defaults are `640x480 @ 30fps` on `/dev/video0`. To change them, edit the systemd
unit and reload:

```bash
sudo nano /etc/systemd/system/picam-display.service   # VIDEO_SIZE, VIDEO_FPS, VIDEO_DEVICE
sudo systemctl daemon-reload
sudo systemctl restart picam-display
```

Or pass them at install time:

```bash
sudo VIDEO_SIZE=352x288 VIDEO_FPS=30 bash ~/setup/install.sh
```

## Troubleshooting

**Laggy / low FPS** — almost always means the GPU driver isn't active. Check:

```bash
ls -l /dev/dri/            # want a renderD128 node
```

If there's no `renderD*`, the v3d driver isn't loaded — run `sudo raspi-config`
→ Advanced Options and enable the GL (Fake KMS / Full KMS) driver.

**`Could not find any preferred mode. Picking the first mode.`** — mpv isn't
reading the screen's native resolution. Pin the output in the service file:

```
Environment=DISPLAY_CONNECTOR=HDMI-A-1     # or DSI-1 for the touchscreen
```

**Screen goes blank after a while** — that's display sleep, not a crash. Add
`consoleblank=0` to the kernel command line (`/boot/firmware/cmdline.txt`) to
disable it.

**Manual test** (before wiring autostart):

```bash
mpv --vo=gpu --gpu-context=drm --fs \
    --profile=low-latency --cache=no --untimed --framedrop=vo \
    --demuxer-lavf-o=video_size=640x480,input_format=mjpeg,framerate=30 \
    av://v4l2:/dev/video0
```

## Files

```
setup/
  install.sh                 # one-shot installer (run as root on the Pi)
  display/display.sh         # the mpv fullscreen launcher
  systemd/picam-display.service  # autostart unit (templated)
```
