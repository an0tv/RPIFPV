#!/usr/bin/env bash
#
# netd.sh — Wi-Fi supervisor for the Pi Zero 2 W (NetworkManager / Bookworm).
#
# Runs continuously (systemd Type=simple) and keeps the Pi reachable:
#
#   mode = auto   (default)
#     * try to stay joined to the saved network
#     * if the link becomes unusable (gateway unreachable for AP_FALLBACK s),
#       switch to hosting our own Access Point
#     * while on the AP, periodically retry joining the saved network
#   mode = ap     force the access point (never auto-rejoin)
#   mode = sta    force joining the saved network (never fall back to AP)
#
# The mode is read from /etc/picam/wifi.json ("mode": auto|ap|sta) and re-read
# every loop, so the web UI can change it without restarting this service.
#
set -euo pipefail

CONF=/etc/picam/wifi.json
LOG=/var/log/picam/netd.log
WIFI_IF="${WIFI_IF:-wlan0}"
AP_IP="${AP_IP:-10.42.0.1}"                  # NM hotspot default gateway

# Tunables (seconds)
LOOP_INTERVAL="${LOOP_INTERVAL:-5}"          # how often to re-evaluate
AP_FALLBACK="${AP_FALLBACK:-20}"             # STA must be unreachable this long before AP
STA_RETRY="${STA_RETRY:-60}"                 # retry STA every N seconds while on AP
STA_CONNECT_TIMEOUT="${STA_CONNECT_TIMEOUT:-15}"  # bound each nmcli connect attempt

log() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

# --- read a JSON field with python3 (always present on Bookworm) -----------
json_get() { python3 -c "import json,sys;d=json.load(open('$CONF'));print(d.get('$1','') or '')" 2>/dev/null || echo ""; }

# --- link probes -----------------------------------------------------------
# True if wlan0 is currently hosting an AP (802-11 mode == ap).
ap_active() {
  nmcli -t -f 802-11-wireless.mode connection show --active 2>/dev/null | grep -qx 'ap'
}

# True if we can reach the default gateway (i.e. we're on a working network).
# While hosting the AP there is no default route, so this is false — that's the
# reliable way to tell "healthy client" from "hosting AP / dead link".
gateway_up() {
  local gw; gw=$(ip route | awk '/default/{print $3; exit}' 2>/dev/null)
  [ -n "$gw" ] && ping -c1 -W1 "$gw" >/dev/null 2>&1
}

# SSID of the network in use ('*' marks the IN-USE row), or empty.
connected_ssid() {
  nmcli -t -f IN-USE,SSID dev wifi list 2>/dev/null | grep '^\*:' | cut -d: -f2- | head -1
}

# --- actions ---------------------------------------------------------------
start_sta() { # $1=ssid  $2=password(optional)
  local ssid="$1" pw="${2:-}"
  log "joining network '$ssid'"
  nmcli dev disconnect "$WIFI_IF" >/dev/null 2>&1 || true
  local args=(dev wifi connect "$ssid" ifname "$WIFI_IF")
  if [ -n "$pw" ]; then args+=(password "$pw"); fi
  timeout "$STA_CONNECT_TIMEOUT" nmcli "${args[@]}" >/dev/null 2>&1
}

start_ap() { # $1=ap_ssid  $2=ap_password
  local ap_ssid="$1" ap_pw="${2:-}"
  if ap_active; then return 0; fi
  log "starting access point '$ap_ssid' (IP $AP_IP)"
  nmcli radio wifi off >/dev/null 2>&1 || true
  sleep 1
  nmcli radio wifi on  >/dev/null 2>&1 || true
  local args=(dev wifi hotspot ifname "$WIFI_IF" ssid "$ap_ssid")
  if [ -n "$ap_pw" ]; then args+=(password "$ap_pw"); fi
  timeout "$STA_CONNECT_TIMEOUT" nmcli "${args[@]}" >/dev/null 2>&1 \
    || log "hotspot command failed (may still be coming up)"
}

# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG")"
need nmcli; need python3; need ping; need ip; need timeout
[ -f "$CONF" ] || die "config $CONF not found (run install.sh first)"

wifi_on() { nmcli radio wifi on >/dev/null 2>&1 || true; }
wifi_on

log "supervisor started (auto watchdog: AP after ${AP_FALLBACK}s outage)"

# Tracked state
outage_start=0          # epoch when we first noticed the link unusable
last_retry=0            # epoch of last STA rejoin attempt
last_role=""            # previous role, to log only on change

while true; do
  now=$(date +%s)

  SSID=$(json_get ssid)
  PASS=$(json_get password)
  APSSID=$(json_get ap_ssid);   [ -n "$APSSID" ] || APSSID="picam"
  APPASS=$(json_get ap_password)
  MODE=$(json_get mode);        [ -n "$MODE" ] || MODE="auto"
  case "$MODE" in auto|ap|sta) ;; *) MODE="auto" ;; esac

  case "$MODE" in
    ap)
      start_ap "$APSSID" "$APPASS"
      role="ap"
      ;;
    sta)
      if [ -n "$SSID" ] && [ "$(connected_ssid)" != "$SSID" ]; then
        if [ $((now - last_retry)) -ge "$STA_RETRY" ]; then
          last_retry=$now
          start_sta "$SSID" "$PASS" || true
        fi
      fi
      role="sta"
      ;;
    auto)
      if ap_active; then
        # Hosting AP: retry the saved network periodically.
        role="ap"
        if [ -n "$SSID" ] && [ $((now - last_retry)) -ge "$STA_RETRY" ]; then
          last_retry=$now
          log "AP active; retrying saved network '$SSID'"
          start_sta "$SSID" "$PASS" || true
        fi
        outage_start=0
      elif gateway_up; then
        # Healthy client.
        role="client"
        outage_start=0
      else
        # Link down or unusable (interference / out of range).
        role="client-down"
        if [ -n "$SSID" ]; then
          # Rejoin attempt, throttled.
          if [ $((now - last_retry)) -ge "$STA_RETRY" ]; then
            last_retry=$now
            log "link down; re-joining '$SSID'"
            start_sta "$SSID" "$PASS" || true
          fi
        fi
        if [ "$outage_start" -eq 0 ]; then outage_start=$now; fi
        if [ $((now - outage_start)) -ge "$AP_FALLBACK" ]; then
          log "unreachable for ${AP_FALLBACK}s; switching to AP"
          start_ap "$APSSID" "$APPASS"
          outage_start=0
        fi
      fi
      ;;
    *)
      # unreachable: normalized to auto above
      ;;
  esac

  if [ "$role" != "$last_role" ]; then
    log "role: $role (mode=$MODE)"
    last_role="$role"
  fi

  sleep "$LOOP_INTERVAL"
done
