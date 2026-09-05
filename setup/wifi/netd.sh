#!/usr/bin/env bash
#
# netd.sh — Wi-Fi role manager for the Pi Zero 2 W (NetworkManager / Bookworm).
#
# Behaviour (matches your requirement):
#   1. Read the saved network from /etc/picam/wifi.json (written by the web UI).
#   2. Try to join that network; if connected, stay in STA (client) mode.
#   3. If there is no saved network, or we cannot connect within CONNECT_TIMEOUT
#      seconds, fall back to hosting our own Access Point (hotspot) so the web
#      UI is always reachable.
#
# The systemd unit is ONESHOT and stateless: each start re-reads wifi.json and
# makes one decision. After saving new credentials the web UI runs
# `systemctl restart picam-net`, which re-runs this script.
#
set -euo pipefail

CONF=/etc/picam/wifi.json
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"     # seconds to wait before AP fallback
WIFI_IF="${WIFI_IF:-wlan0}"
LOG=/var/log/picam/netd.log
AP_IP="${AP_IP:-10.42.0.1}"                  # NM hotspot default gateway

# Writes to both stdout (captured by journald) and the log file.
log() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1 (install it, e.g. nmcli from network-manager)"; }

# --- read a JSON field with python3 (always present on Bookworm) -----------
json_get() { python3 -c "import json,sys;d=json.load(open('$CONF'));print(d.get('$1','') or '')" 2>/dev/null || echo ""; }

wifi_on() { nmcli radio wifi on >/dev/null 2>&1 || true; }

# True if wlan0 is currently hosting an AP (802-11 mode == ap).
ap_active() {
  nmcli -t -f 802-11-wireless.mode connection show --active 2>/dev/null | grep -qx 'ap'
}

# True if wlan0 has an active connection (client or AP). Terse nmcli with one
# field prints the bare value, e.g. "100 (connected)" / "30 (disconnected)".
# Match the parenthesized word so "disconnected" is NOT treated as connected.
net_is_up() {
  nmcli -t -f GENERAL.STATE device show "$WIFI_IF" 2>/dev/null | grep -q '(connected)'
}

# SSID of the network in use ('*' marks the IN-USE row), or empty.
connected_ssid() {
  nmcli -t -f IN-USE,SSID dev wifi list 2>/dev/null | grep '^\*:' | cut -d: -f2- | head -1
}

start_sta() { # $1=ssid  $2=password(optional)
  local ssid="$1" pw="${2:-}"
  log "attempting to join network '$ssid'"
  # Drop whatever we're on (e.g. the AP) so wlan0 is free to join as a client.
  nmcli dev disconnect "$WIFI_IF" >/dev/null 2>&1 || true
  if [ -n "$pw" ]; then
    nmcli dev wifi connect "$ssid" password "$pw" ifname "$WIFI_IF" >/dev/null 2>&1 \
      || { log "nmcli connect failed for '$ssid'"; return 1; }
  else
    nmcli dev wifi connect "$ssid" ifname "$WIFI_IF" >/dev/null 2>&1 \
      || { log "nmcli connect failed (open net?) for '$ssid'"; return 1; }
  fi
}

start_ap() { # $1=ap_ssid  $2=ap_password
  local ap_ssid="$1" ap_pw="${2:-}"
  if ap_active; then
    log "access point already active ('$ap_ssid')"
    return 0
  fi
  log "starting access point '$ap_ssid' (IP $AP_IP)"
  # Bring up a NetworkManager hotspot; NM runs hostapd + dnsmasq and assigns
  # the gateway IP $AP_IP to wlan0, handing out addresses to clients.
  nmcli radio wifi off >/dev/null 2>&1 || true
  sleep 1
  nmcli radio wifi on  >/dev/null 2>&1 || true
  if [ -n "$ap_pw" ]; then
    nmcli dev wifi hotspot ifname "$WIFI_IF" ssid "$ap_ssid" password "$ap_pw" >/dev/null 2>&1 \
      || die "failed to start hotspot"
  else
    nmcli dev wifi hotspot ifname "$WIFI_IF" ssid "$ap_ssid" >/dev/null 2>&1 \
      || die "failed to start open hotspot"
  fi
}

# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG")"
need nmcli; need python3
[ -f "$CONF" ] || die "config $CONF not found (run install.sh first)"

SSID=$(json_get ssid)
PASS=$(json_get password)
APSSID=$(json_get ap_ssid);   [ -n "$APSSID" ] || APSSID="picam"
APPASS=$(json_get ap_password)

wifi_on

# --- decide ----------------------------------------------------------------
if [ -n "$SSID" ]; then
  if [ "$(connected_ssid)" = "$SSID" ]; then
    log "already connected to desired network '$SSID'"
    exit 0
  fi
  # try to join within CONNECT_TIMEOUT seconds
  start_sta "$SSID" "$PASS" || true
  for ((i=0;i<CONNECT_TIMEOUT;i++)); do
    if [ "$(connected_ssid)" = "$SSID" ]; then
      log "connected to '$SSID'"
      exit 0
    fi
    sleep 1
  done
  log "could not connect to '$SSID' within ${CONNECT_TIMEOUT}s"
else
  log "no saved network configured"
  if ap_active; then
    log "access point already active; staying in AP mode"
    exit 0
  fi
  if net_is_up; then
    log "already connected to a network; staying in STA mode"
    exit 0
  fi
fi

# fall through to AP mode
start_ap "$APSSID" "$APPASS"
log "now in AP mode at http://${AP_IP}:8080 (SSID '$APSSID')"
