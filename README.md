# PiCam — Raspberry Pi Zero 2 W camera streamer

Stream a USB **CVBS / S-Video capture dongle** (Arkmicro `18ec:5850`, appears as a
plain UVC V4L2 device `/dev/video0`) to a web browser with **low latency and few
viewers**, on a Raspberry Pi Zero 2 W.

It also runs its **own fallback Wi-Fi access point**, so the Pi is always
reachable even when it can't join your home network — and the same web page that
shows the video lets you type in a network name + password to rejoin after reboot.

```
Arkmicro CVBS/S-Video dongle            the Pi Zero 2 W
  └─ USB UVC → /dev/video0  ──►  go2rtc  (captures + serves WebRTC / MSE)
                                      │   http://<pi>:1984/stream.html?src=camera
                                      │   (lazy start: ~0 CPU when nobody watching)
                                      ▼
                              browser viewer (WebRTC ≈ low latency)
```

## Architecture

| Piece | Role |
|---|---|
| **go2rtc** | Single static daemon. Captures the V4L2 device (native MJPEG passthrough by default) and re-serves it to browsers with WebRTC / MSE / MJPEG auto-negotiation. |
| **picam-net** (netd.sh) | Wi-Fi supervisor daemon. `auto` mode keeps the saved network joined and switches to its own AP (`picam`) if the link becomes unreachable for ~20 s, retrying the network periodically. Also supports forced `ap` / `sta` modes from the UI. |
| **picam-portal** (portal.py) | Small web UI + API on `:8080`: embeds the live stream and the "join this Wi-Fi" form. |
| **picam-camera** | systemd unit that keeps go2rtc alive. |

> **Why passthrough, not re-encode?** The Arkmicro dongle already emits **MJPEG**
> natively, so go2rtc serves it as-is at **near-zero CPU** (this is what go2rtc's
> own device enumerator does for "compressed" UVC formats). Re-encoding to H.264
> in software is what caused `ffmpeg` to pin the Zero 2 W at ~270% CPU. Keep the
> `h264` mode available only if you need a classic MSE `<video>` and accept the
> CPU/load, or have a Pi 4/5 with usable hardware encoding.

## What's here

```
setup/
  install.sh            # one-shot installer (run on the Pi, as root)
  cam-detect.sh         # probes the dongle, prints a go2rtc source line
  wifi/netd.sh          # Wi-Fi supervisor daemon (auto AP fallback + forced modes)
  wifi/wifi.default.json
  web/portal.py         # :8080 UI + config API
  web/index.html        # viewer + network + mode controls
  systemd/picam-camera.service
  systemd/picam-net.service
  systemd/picam-portal.service
```

## Quick start

1. **Burn Raspberry Pi OS Bookworm (Lite)** and enable SSH. Pre-seed Wi-Fi is
   optional — if you skip it, first boot lands on the AP (below).

2. **Copy this repo to the Pi** and install:

   ```bash
   scp -r setup pi@<ip>:~/
   ssh pi@<ip>
   sudo bash ~/setup/install.sh
   ```

3. **Watch** — open one of:
   - `http://<pi-ip>:8080` — combined page (stream + network settings)
   - `http://<pi-ip>:1984/stream.html?src=camera` — plain go2rtc player

### First boot / no network reachable (fallback AP)

If the Pi can't join a saved network, or its connection drops for ~20 s
(e.g. 2.4 GHz interference), it starts an access point:

- **SSID:** `picam`
- **Password:** `picam1234`
- **Web UI:** `http://10.42.0.1:8080`

Connect to that network with your phone/laptop, open the page, and use the
**Network** box to enter your real Wi-Fi **name + password**. The Pi will try to
join that network immediately and again after every reboot, and the AP comes
back automatically if the network ever becomes unreachable.

**The three mode buttons** in the UI:

- **Auto** (default) — stay on the saved network; fall back to the AP when it's
  unreachable, and rejoin automatically when it comes back.
- **AP** — force the access point now (handy when you're going to be next to the
  Pi with no network, e.g. in the field).
- **Wi-Fi** — force joining the saved network (no AP fallback).

> Change the AP credentials/name by editing `/etc/picam/wifi.json`
> (`ap_ssid`, `ap_password`). The mode is read live — no restart needed.
> Note: WPA2 requires the AP password to be **8+ characters**.

## Tuning & operations

**Camera not detected?** Plug it in and run:

```bash
sudo /opt/picam/cam-detect.sh            # inspect + print recommended source (passthrough)
sudo /opt/picam/cam-detect.sh h264       # force software H.264 re-encode (high CPU)
```

Edit `/etc/picam/go2rtc.yaml` streams→camera with the printed line, then
`systemctl restart picam-camera`.

**PAL vs NTSC / which resolution.** The dongle usually advertises both
`720x576` (PAL) and `720x480` (NTSC) MJPEG modes. `cam-detect.sh` picks the
largest advertised size. If the picture is half-height or rolling, force the
other standard, e.g. set the source to `...&video_size=720x480` (NTSC) or
`720x576` (PAL), matching your camera's CVBS signal.

**Low-latency mode.** The go2rtc player defaults to WebRTC (best latency) when
the stream is H.264, and falls back to MJPEG/MSE automatically otherwise. MJPEG
passthrough is also low-latency.

**Logs / status**

```bash
journalctl -u picam-camera -f    # go2rtc / ffmpeg
journalctl -u picam-net -f       # wifi role decisions
tail -f /var/log/picam/netd.log
curl http://localhost:8080/api/wifi      # current role + connected ssid
```

**Security note.** The UI and go2rtc are unauthenticated on your LAN by default.
The stream URL is deterministic. For internet exposure, put Caddy/nginx in front
with Basic Auth + HTTPS, and do **not** expose the `:8080` config API — it can
rewrite Wi-Fi credentials and reboot the device.

## Known limits on the Zero 2 W

- 2.4 GHz Wi-Fi only: keep the H.264 bitrate modest (default go2rtc encoder is
  fine) and it comfortably serves 1–3 viewers. Onboard Wi-Fi and the USB dongle
  can share the bus; a powered USB hub helps if the dongle is flaky.
- MJPEG passthrough uses essentially no CPU, so the Zero 2 W idles even while
  streaming. The tradeoff is higher per-viewer bandwidth than H.264; with 1–3
  viewers on the 2.4 GHz LAN that's fine.
- AP and client share the one radio: while in AP mode the Pi is *not* on your
  LAN, and vice-versa (see `picam-net`). The supervisor switches between them
  automatically in `auto` mode.

## Files reference

- `/etc/picam/wifi.json` — persisted network + AP settings + `mode` (chmod 600)
- `/etc/picam/go2rtc.yaml` — streaming config
- `/opt/picam/go2rtc` — go2rtc binary
- `/opt/picam/netd.sh`, `/opt/picam/cam-detect.sh`, `/opt/picam/web/` — controller, camera probe, portal
- `/var/log/picam/netd.log` — Wi-Fi role decisions
