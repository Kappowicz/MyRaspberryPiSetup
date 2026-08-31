#!/bin/bash
# Layer 1: heartbeat to Healthchecks.io - a dead man's switch.
#
# The host pings every 5 minutes. When it stops pinging, Healthchecks shouts
# AT YOU. This is the only alarm that works when the host is DEAD: no power,
# severed network, failed SSD. Every other layer goes quiet along with it -
# the dead do not shout. That is why this one has to live outside.
#
#   ./heartbeat.sh                  - ping once (this is what the timer calls)
#   ./heartbeat.sh --set <url>      - store the ping URL from Healthchecks.io
#   ./heartbeat.sh --show           - show what is configured

set -u
CONF="${HEARTBEAT_CONF:-$HOME/.config/secrets/heartbeat.env}"
QUEUE="$HOME/alerts/queue"
RESOLVER=1.1.1.1
QUEUE_THRESHOLD=1800   # 30 minutes

case "${1:-}" in
  --set)
    [ $# -eq 2 ] || { echo "usage: $0 --set https://hc-ping.com/<UUID>" >&2; exit 1; }
    case "$2" in https://hc-ping.com/*) ;; *) echo "heartbeat: url must start with https://hc-ping.com/" >&2; exit 1 ;; esac
    umask 077; printf 'HC_URL=%s\n' "$2" > "$CONF"; chmod 600 "$CONF"
    echo "heartbeat: saved to $CONF"; exit 0 ;;
  --show)
    [ -r "$CONF" ] && cat "$CONF" || echo "heartbeat: missing $CONF - run --set first"; exit 0 ;;
esac

[ -r "$CONF" ] || { echo "heartbeat: missing $CONF. Run: $0 --set https://hc-ping.com/<UUID>" >&2; exit 78; }
# shellcheck source=/dev/null
. "$CONF"
[ -n "${HC_URL:-}" ] || { echo "heartbeat: HC_URL is empty in $CONF" >&2; exit 78; }

NOW=$(date +%s)

# The notification queue is the blind spot of the whole system: if ntfy stops
# accepting, alarms pile up on disk and NOTHING says so, because the only
# channel that could is the broken one. So a stuck queue is reported here -
# over an independent path with its own notifications (email from
# Healthchecks). The independent path reports the failure of the dependent one.
OLDEST=0
COUNT=0
for f in "$QUEUE"/*.msg; do
  [ -e "$f" ] || break
  COUNT=$(( COUNT + 1 ))
  e=$(basename "$f"); e=${e%%-*}
  case "$e" in ''|*[!0-9]*) continue ;; esac
  if [ "$OLDEST" -eq 0 ] || [ "$e" -lt "$OLDEST" ]; then OLDEST=$e; fi
done

TARGET="$HC_URL"
WARNING=""
if [ "$OLDEST" -ne 0 ]; then
  AGE=$(( NOW - OLDEST ))
  if [ "$AGE" -ge "$QUEUE_THRESHOLD" ]; then
    TARGET="$HC_URL/fail"
    WARNING="!! NOTIFICATIONS ARE NOT GOING OUT
$COUNT queued, oldest waiting $(( AGE / 60 )) min. ntfy is not accepting them.
The host is ALIVE - this is a notification-channel failure, not a hardware one.
Check: ~/notify.sh status; ~/notify.sh queue; cat ~/.config/secrets/notify.env
"
  fi
fi

# Ping body. Healthchecks keeps the last few, so during an outage you can see
# from your phone how the host was doing JUST BEFORE it went quiet. For free.
BODY="${WARNING}$(date '+%Y-%m-%d %H:%M:%S %Z')
uptime:$(uptime -p 2>/dev/null)
load:$(cut -d' ' -f1-3 /proc/loadavg)
disk:$(df -h / | awk 'NR==2{print $5" used, "$4" free"}')
temp:$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2)
throttled:$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
failed_units:$(systemctl --user --failed --no-legend 2>/dev/null | wc -l)
queued_alerts:$COUNT"

ping_once() {
  curl -fsS --connect-timeout 5 -m 10 --retry 2 --retry-delay 3 \
    --data-raw "$BODY" "$TARGET" >/dev/null 2>&1 && return 0
  # Same trap as with ntfy: Pi-hole is this host's resolver and is itself a
  # plausible failure. The heartbeat must get out then too - otherwise
  # Healthchecks declares the host dead when it is alive with broken DNS.
  local ip
  ip=$(dig +short +time=3 +tries=1 "@$RESOLVER" hc-ping.com A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
  [ -n "$ip" ] || return 1
  curl -fsS --connect-timeout 5 -m 10 --retry 2 --retry-delay 3 \
    --resolve "hc-ping.com:443:$ip" --data-raw "$BODY" "$TARGET" >/dev/null 2>&1
}

ping_once || { echo "heartbeat: ping failed" >&2; exit 1; }
[ -n "$WARNING" ] && echo "heartbeat: reported a CHANNEL FAILURE (queue is stuck)" >&2
exit 0
