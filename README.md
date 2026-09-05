# OpenIPC — Raspberry Pi Zero 2 W camera streamer

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
| **go2rtc** | Single static daemon. Captures the V4L2 device (via ffmpeg device input, software x264) and re-serves it to browsers with WebRTC / MSE auto-negotiation. |
| **openipc-net** (netd.sh) | On boot tries to join the network saved in `/etc/openipc/wifi.json`; if it can't within **15 s**, starts its own AP (`openipc-cam`) via NetworkManager. |
| **openipc-portal** (portal.py) | Small web UI + API on `:8080`: embeds the live stream and the "join this Wi-Fi" form. |
| **openipc-camera** | systemd unit that keeps go2rtc alive. |

> **Why software x264 and not the GPU encoder?** The Zero 2 W uses the same SoC
> as a Pi 3, whose H.264 block isn't usable for generic UVC input and is anyway
> too slow there (see go2rtc hardware docs). Software H.264 of an SD
> (720×576/720×480) source is very achievable and keeps multi-viewer bandwidth low.
> The device natively serves MJPEG, so `cam-detect.sh passthrough` is available
> as a **zero-CPU** alternative if you only need one viewer / accept higher
> bandwidth.

## What's here

```
setup/
  install.sh            # one-shot installer (run on the Pi, as root)
  cam-detect.sh         # probes the dongle, prints a go2rtc source line
  wifi/netd.sh          # STA-or-AP role manager
  wifi/wifi.default.json
  web/portal.py         # :8080 UI + config API
  web/index.html        # viewer + "join a network" page
  systemd/openipc-camera.service
  systemd/openipc-net.service
  systemd/openipc-portal.service
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

If the Pi can't join any saved network within 15 s, it starts an access point:

- **SSID:** `openipc-cam`
- **Password:** `openipc-cam`
- **Web UI:** `http://10.42.0.1:8080`

Connect to that network with your phone/laptop, open the page, and use the
**Network** box to enter your real Wi-Fi **name + password**. The Pi will try to
join that network immediately and again after every reboot. If it can never join,
the AP comes back so you always have a way in.

> Change the AP credentials/name by editing `/etc/openipc/wifi.json`
> (`ap_ssid`, `ap_password`) then `systemctl restart openipc-net`.

## Tuning & operations

**Camera not detected?** Plug it in and run:

```bash
sudo /opt/openipc/cam-detect.sh            # inspect + print recommended source
sudo /opt/openipc/cam-detect.sh passthrough   # zero-CPU MJPEG
```

Edit `/etc/openipc/go2rtc.yaml` streams→camera with the printed line, then
`systemctl restart openipc-camera`.

**PAL vs NTSC / which resolution.** The dongle usually advertises both
`720x576` (PAL) and `720x480` (NTSC) MJPEG modes. `cam-detect.sh` picks the
largest advertised size. If the picture is half-height or rolling, force the
other standard, e.g. set the source to `...&video_size=720x480` (NTSC) or
`720x576` (PAL), matching your camera's CVBS signal.

**Low-latency mode.** The go2rtc player defaults to WebRTC (best latency). The
software x264 encode already uses `-tune zerolatency`. For weaker clients go2rtc
falls back to MSE automatically.

**Logs / status**

```bash
journalctl -u openipc-camera -f    # go2rtc / ffmpeg
journalctl -u openipc-net -f       # wifi role decisions
tail -f /var/log/openipc-net.log
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
- Software encode uses a few cores while someone is watching; with no viewers
  go2rtc stops the encoder (idle ≈ 0%).
- AP and client share the one radio: while in AP mode the Pi is *not* on your
  LAN, and vice-versa (see `openipc-net`).

## Files reference

- `/etc/openipc/wifi.json` — persisted network + AP settings (chmod 600)
- `/etc/openipc/go2rtc.yaml` — streaming config
- `/opt/openipc/go2rtc` — go2rtc binary
- `/opt/openipc/netd.sh`, `/opt/openipc/web/` — controller + portal
