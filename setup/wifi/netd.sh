#!/usr/bin/env bash
#
# netd.sh — Wi-Fi role manager for the Pi Zero 2 W (NetworkManager / Bookworm).
#
# Behaviour (matches your requirement):
#   1. Read the saved network from /etc/openipc/wifi.json (written by the web UI).
#   2. Try to join that network; if connected, stay in STA (client) mode.
#   3. If there is no saved network, or we cannot connect within CONNECT_TIMEOUT
#      seconds, fall back to hosting our own Access Point (hotspot) so the web
#      UI is always reachable.
#   4. `netd.sh reconnect` is used by the web UI after it saves new credentials;
#      it tears down the AP (dropping the current client) and retries STA.
#
# The service is ONESHOT and stateless: each start re-reads wifi.json and makes
# one decision. The web UI triggers re-evaluation with: systemctl restart openipc-net
#
set -euo pipefail

CONF=/etc/openipc/wifi.json
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"     # seconds to wait before AP fallback
WIFI_IF="${WIFI_IF:-wlan0}"
LOG_TAG="openipc-net"
AP_IP="${AP_IP:-10.42.0.1}"                  # NM hotspot default gateway

log() { echo "[$(date -Is)] $*" | tee -a /var/log/openipc-net.log | systemd-cat -t "$LOG_TAG" >/dev/null 2>&1 || echo "[$(date -Is)] $*"; }
die() { log "ERROR: $*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1 (install it, e.g. nmcli from network-manager)"; }

# --- read a JSON field with python3 (always present on Bookworm) -----------
json_get() { python3 -c "import json,sys;d=json.load(open('$CONF'));print(d.get('$1','') or '')" 2>/dev/null || echo ""; }

wifi_on()  { nmcli radio wifi on >/dev/null 2>&1 || true; }
net_is_up() {
  # true if wlan0 has an active connection
  local st; st=$(nmcli -t -f GENERAL.STATE device show "$WIFI_IF" 2>/dev/null | cut -d: -f2 || true)
  case "$st" in
    connected|100\ \(connected\)) return 0 ;;
    *) return 1 ;;
  esac
}
connected_ssid() {
  nmcli -t -f active,ssid dev wifi list 2>/dev/null | grep '^yes:' | cut -d: -f2 || true
}

start_sta() { # $1=ssid  $2=password(optional)
  local ssid="$1" pw="${2:-}"
  log "attempting to join network '$ssid'"
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
need nmcli; need python3
[ -f "$CONF" ] || die "config $CONF not found (run install.sh first)"

SSID=$(json_get ssid)
PASS=$(json_get password)
APSSID=$(json_get ap_ssid);   [ -n "$APSSID" ] || APSSID="openipc-cam"
APPASS=$(json_get ap_password)

wifi_on

ACTION="${1:-run}"
case "$ACTION" in
  reconnect)
    # drop whatever we're on and force a fresh STA attempt (or AP fallback)
    nmcli dev disconnect "$WIFI_IF" >/dev/null 2>&1 || true
    sleep 2
    ;;
  run) ;;
  *) die "usage: $0 [run|reconnect]" ;;
esac

# --- decide ----------------------------------------------------------------
if [ -n "$SSID" ]; then
  if connected_ssid | grep -qx "$SSID"; then
    log "already connected to desired network '$SSID'"
    exit 0
  fi
  # try to join within CONNECT_TIMEOUT seconds
  start_sta "$SSID" "$PASS" || true
  for ((i=0;i<CONNECT_TIMEOUT;i++)); do
    if connected_ssid | grep -qx "$SSID"; then
      log "connected to '$SSID'"
      exit 0
    fi
    sleep 1
  done
  log "could not connect to '$SSID' within ${CONNECT_TIMEOUT}s"
else
  log "no saved network configured"
  if net_is_up; then
    log "already connected to a network; staying in STA mode"
    exit 0
  fi
fi

# fall through to AP mode
start_ap "$APSSID" "$APPASS"
log "now in AP mode at http://${AP_IP}:8080 (SSID '$APSSID')"
