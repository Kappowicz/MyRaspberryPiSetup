#!/bin/bash
# Layer 2 and 5: data freshness, DNS, hardware and resource thresholds.
#
# Run from a timer every 5 minutes. It never sends anything directly -
# everything goes through ~/notify.sh, i.e. through the on-disk queue. If the
# host loses internet the notification stays on disk and arrives on the next
# run.
#
#   ./check.sh          - normal run
#   ./check.sh -v       - same, but chatty on stdout (for debugging)

set -u
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
say(){ [ $VERBOSE -eq 1 ] && echo "$@"; return 0; }

CONF="${ALERTS_CONF:-$HOME/.config/alerts.conf}"
[ -r "$CONF" ] || { echo "check: missing $CONF" >&2; exit 1; }
# shellcheck source=/dev/null
. "$CONF"

NOTIFY="$HOME/notify.sh"
STATE="$HOME/alerts/state"
mkdir -p "$STATE"

# How long to wait before repeating an alert that is still firing. Without this
# you get one notification and then silence - and a week later you have no idea
# whether it is still broken. With it: a reminder every 6 hours.
REPEAT=21600

# Thresholds. Derived from the write interval, with headroom.
SDS011_MAX=2100     # 35 min; the sensor writes every 10 min (sleep 585+15)
GIOS_MAX=10800      # 3 h; GIOS publishes hourly, usually ~30 min behind
INFLUX_DEBOUNCE=600 # 10 min; a single failed query is not an outage

# Backlog first. If the internet just came back, this is the moment old
# notifications should fly.
"$NOTIFY" queue >/dev/null 2>&1

duration() { # seconds -> "6 h 12 min" or "43 min"
  local h=$(( $1 / 3600 )) m=$(( ($1 % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then echo "$h h $m min"; else echo "$m min"; fi
}

flux() {
  curl -s --max-time 15 -XPOST "$INFLUX_URL/api/v2/query?org=$INFLUX_ORG" \
    -H "Authorization: Token $INFLUX_TOKEN" \
    -H "Content-Type: application/vnd.flux" -H "Accept: application/csv" \
    --data-binary "$1"
}

series_age() { # $1=sensor $2=field -> seconds | NONE | ERROR
  local o t
  o=$(flux "from(bucket:\"$INFLUX_BUCKET\")
    |> range(start:-30d)
    |> filter(fn:(r)=> r._measurement==\"air_quality\" and r.sensor==\"$1\" and r._field==\"$2\")
    |> last()
    |> map(fn:(r)=>({ t: int(v: r._time)/1000000000 }))
    |> keep(columns:[\"t\"])")
  [ -z "$o" ] && { echo ERROR; return; }
  # A Flux error response is also non-empty - we tell them apart by the
  # presence of a data row.
  t=$(printf '%s' "$o" | tr -d '\r' | awk -F, '/^,_result/{print $NF}' | tail -1)
  case "$t" in
    ''|*[!0-9]*) case "$o" in *error*) echo ERROR ;; *) echo NONE ;; esac ;;
    *) echo $(( $(date +%s) - t )) ;;
  esac
}

evaluate() { # $1=name $2=bad|ok $3=debounce $4=channel $5=title $6=body
  local name=$1 result=$2 deb=$3 channel=$4 title=$5 body=$6
  local file="$STATE/$name" now BAD_SINCE=0 NOTIFIED=0
  now=$(date +%s)
  # shellcheck source=/dev/null
  [ -f "$file" ] && . "$file"

  if [ "$result" = bad ]; then
    [ "$BAD_SINCE" -eq 0 ] && BAD_SINCE=$now
    if [ $(( now - BAD_SINCE )) -ge "$deb" ] && [ $(( now - NOTIFIED )) -ge "$REPEAT" ]; then
      say "  -> NOTIFYING ($channel): $title"
      # A 6-hour repeat must LOOK different from the first alarm, otherwise you
      # cannot tell a new failure from a reminder about an old one.
      if [ "$NOTIFIED" -eq 0 ]; then
        "$NOTIFY" "$channel" "$title" \
          "Started at $(date -d "@$BAD_SINCE" '+%H:%M').

$body" >/dev/null 2>&1
      else
        "$NOTIFY" "$channel" "REMINDER ($(duration $(( now - BAD_SINCE )))): $title" \
          "Ongoing since $(date -d "@$BAD_SINCE" '+%d.%m %H:%M'), that is $(duration $(( now - BAD_SINCE ))).

$body" >/dev/null 2>&1
      fi
      NOTIFIED=$now
    else
      say "  -> bad, but still quiet (debounce/repeat)"
    fi
    printf 'BAD_SINCE=%s\nNOTIFIED=%s\n' "$BAD_SINCE" "$NOTIFIED" > "$file"
  else
    # Recovery is only reported if something actually went out before.
    # Otherwise you would get a "recovered" after every momentary blip.
    if [ "$NOTIFIED" -ne 0 ]; then
      say "  -> RECOVERED: $title"
      "$NOTIFY" done "Back to normal: $title" \
        "All good again. The failure lasted $(duration $(( now - BAD_SINCE )))." >/dev/null 2>&1
    fi
    rm -f "$file"
  fi
}

# --------------------------------------------------------------- rules

# --- DNS: does Pi-hole actually ANSWER ---------------------------------------
# "systemctl is-active pihole" only says the container is alive. FTL can be
# stuck, unbound can fail to negotiate DoT, gravity can fall apart mid-update -
# and names stop resolving anyway. This is the most visible failure in the whole
# house, so it cannot wait for the 07:00 daily check.
DNS_OK=$(dig +short +time=3 +tries=1 @127.0.0.1 example.com A 2>/dev/null | grep -cE '^[0-9.]+$')
say "dns: ${DNS_OK:-0} answers"
if [ "${DNS_OK:-0}" -eq 0 ]; then
  evaluate dns bad 300 alarm "DNS is not answering" \
    "Pi-hole is not resolving names. In practice: nothing in the house has internet.
Check, in order:
  systemctl --user status pihole unbound
  dig @127.0.0.1 example.com
  podman logs --tail 40 pihole
  journalctl --user -u unbound -n 40
Right now: set 1.1.1.1 as DNS on the router so the house works while you fix it."
else
  evaluate dns ok 300 alarm "DNS is not answering" ""
fi

# --- blocking: names can resolve fine with an empty gravity
BLOCK=$(dig +short +time=3 +tries=1 @127.0.0.1 doubleclick.net A 2>/dev/null | head -1)
say "blocking: ${BLOCK:-none}"
if [ "${DNS_OK:-0}" -ne 0 ] && [ "$BLOCK" != "0.0.0.0" ]; then
  evaluate blocking bad 300 info "Ad blocking is not working" \
    "doubleclick.net returns '${BLOCK:-nothing}' instead of 0.0.0.0. Names resolve, so the internet works - but gravity is empty or the lists failed to load after an update.
Domain count: podman exec pihole pihole-FTL sqlite3 /etc/pihole/gravity.db 'select count(*) from gravity;'
Rebuild:      podman exec pihole pihole -g"
else
  evaluate blocking ok 300 info "Ad blocking is not working" ""
fi

# --- clock: a drifting clock ruins InfluxDB timestamps and the charts
NTP_SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
say "ntp: ${NTP_SYNC:-?}"
if [ "$NTP_SYNC" = "no" ]; then
  evaluate clock bad 1800 info "Clock is not synchronised" \
    "systemd-timesyncd has not confirmed synchronisation for over 30 minutes. A drifting clock corrupts measurement timestamps in InfluxDB and the charts in Grafana.
There is no backup time source: Pi-hole's own NTP client does not start at all here, because it lacks CAP_SYS_TIME in a rootless container.
Check: timedatectl status; systemctl status systemd-timesyncd"
else
  evaluate clock ok 1800 info "Clock is not synchronised" ""
fi

# --- security updates: the same rake as the CERT blocklist
# unattended-upgrades can stop working silently. It looks enabled, does nothing,
# you stop receiving patches and find out never.
STAMP=/var/lib/apt/periodic/unattended-upgrades-stamp
if [ -f "$STAMP" ]; then
  APT_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$STAMP") ) / 86400 ))
else
  APT_DAYS=999
fi
say "unattended-upgrades: $APT_DAYS days ago"
if [ "$APT_DAYS" -ge 7 ]; then
  evaluate apt bad 0 info "Security updates have stalled" \
    "Last successful unattended-upgrades run: $([ "$APT_DAYS" -ge 999 ] && echo "never - no stamp file" || echo "$APT_DAYS days ago"). The timer is supposed to run daily.
Check:   systemctl list-timers apt-daily-upgrade.timer
Dry run: sudo unattended-upgrade --dry-run -d"
else
  evaluate apt ok 0 info "Security updates have stalled" ""
fi

# ================= layer 5: hardware, resources, restart loops ===============
# These thresholds deliberately live HERE and not in healthcheck.sh. That script
# prints disk, temperature and SMART as bare numbers with no bad() call - so
# layer 4 cannot see them. Verified: bad() appears only in the SERVICES, DNS,
# UPSTREAM ENCRYPTION and BLOCKLISTS sections.

DISK=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')
DISK=${DISK:-0}
say "disk: ${DISK}%"
if [ "$DISK" -ge 95 ]; then
  evaluate disk_critical bad 0 alarm "Disk almost full" \
    "${DISK}% used on /. With no space left InfluxDB stops writing and Pi-hole loses its logs.
Check: df -h /; sudo du -sh /var/log/journal ~/previous-versions ~/backups"
  evaluate disk ok 0 info "Disk is filling up" ""
elif [ "$DISK" -ge 85 ]; then
  evaluate disk bad 0 info "Disk is filling up" "${DISK}% used on /. Warning threshold 85%, critical 95%."
  evaluate disk_critical ok 0 alarm "Disk almost full" ""
else
  evaluate disk ok 0 info "Disk is filling up" ""
  evaluate disk_critical ok 0 alarm "Disk almost full" ""
fi

TEMP=$(vcgencmd measure_temp 2>/dev/null | tr -dc '0-9.' | cut -d. -f1)
say "temp: ${TEMP:-?}C"
if [ -n "$TEMP" ] && [ "$TEMP" -ge 75 ]; then
  evaluate temperature bad 0 info "The host is running hot" \
    "CPU at ${TEMP}C. From around 80C the clock starts throttling and everything slows down."
else
  evaluate temperature ok 0 info "The host is running hot" ""
fi

THROTTLED=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
say "throttled: ${THROTTLED:-?}"
if [ -n "$THROTTLED" ] && [ "$THROTTLED" != "0x0" ]; then
  evaluate throttled bad 0 info "Power or thermal throttling" \
    "get_throttled=$THROTTLED, clean is 0x0. The usual cause is a weak power supply or a poor USB-C cable."
else
  evaluate throttled ok 0 info "Power or thermal throttling" ""
fi

SMART=$(sudo -n /usr/sbin/smartctl -H /dev/sda 2>/dev/null | grep -i "overall-health" | awk '{print $NF}')
say "smart: ${SMART:-?}"
if [ -n "$SMART" ] && [ "$SMART" != "PASSED" ]; then
  evaluate smart bad 0 alarm "SMART reports a disk problem" \
    "overall-health = $SMART. Make a backup BEFORE you start diagnosing anything.
Check: sudo smartctl -a /dev/sda"
else
  evaluate smart ok 0 alarm "SMART reports a disk problem" ""
fi

JOURNAL_MB=$(sudo -n du -sm /var/log/journal 2>/dev/null | cut -f1)
say "journal: ${JOURNAL_MB:-?} MB"
if [ -n "$JOURNAL_MB" ] && [ "$JOURNAL_MB" -ge 18432 ]; then
  evaluate journal bad 0 info "Journal is near its limit" \
    "${JOURNAL_MB} MB of 20480 MB. Past the limit the oldest entries start falling out - and those are the ones you need for a post-mortem."
else
  evaluate journal ok 0 info "Journal is near its limit" ""
fi

# The IPv6 prefix from the ISP is leased and can change without warning. When it
# does, the webserver.acl entry stops matching and phones lose access to the
# panel - with no change on our side. This turns a silent failure into an alert
# with a ready-to-paste fix.
ACL_STATUS=$(python3 "$HOME/alerts/acl_check.py" 2>/dev/null)
say "acl: $(printf '%s' "$ACL_STATUS" | head -1)"
case "$ACL_STATUS" in
  MISMATCH*)
    evaluate acl_prefix bad 0 info "IPv6 prefix changed - the panel will lock out phones" \
      "The ISP renumbered the network. Devices that prefer IPv6 will be refused when opening the Pi-hole panel. From a laptop over IPv4 it still works.

$ACL_STATUS" ;;
  *) evaluate acl_prefix ok 0 info "IPv6 prefix changed - the panel will lock out phones" "" ;;
esac

# The local city-air and sds011 images have their dependencies baked in so the
# containers start without network. The price: they no longer receive patches
# from python:3.11-slim. Without this rule they would go stale silently - the
# same class of failure as the CERT blocklist. Rebuild: ~/rebuild-images.sh
STALE=""
for image in localhost/city-air:latest localhost/sds011:latest; do
  # podman prints the time in Go's format ("2026-08-30 11:10:55.353 +0000 UTC"),
  # not RFC3339. The first field is the plain date in both variants, so this
  # works regardless of the podman version.
  CREATED=$(podman image inspect "$image" --format "{{.Created}}" 2>/dev/null | awk '{print $1}')
  EPOCH=$(date -d "$CREATED" +%s 2>/dev/null || true)
  if [ -z "$EPOCH" ]; then
    # A silent parse failure would mean this rule NEVER fires, and that would
    # look exactly like "everything is fine". That is precisely the trap the
    # first version of this rule fell into.
    STALE="$STALE ${image##*/}(CANNOT-READ-DATE)"
    continue
  fi
  IMG_DAYS=$(( ( $(date +%s) - EPOCH ) / 86400 ))
  [ "$IMG_DAYS" -ge 30 ] && STALE="$STALE ${image##*/}($IMG_DAYS days)"
done
say "local images:${STALE:- fresh}"
if [ -n "$STALE" ]; then
  evaluate local_images bad 0 info "Local images are going stale" \
    "Not rebuilt for over 30 days:$STALE
They have dependencies baked in, so they do not pick up patches from python:3.11-slim on their own.
Rebuild: ~/rebuild-images.sh"
else
  evaluate local_images ok 0 info "Local images are going stale" ""
fi

# A container that restarts SLOWLY (say every 2 minutes) never exhausts
# StartLimitBurst=5 within a 5-minute window, so it never reaches the failed
# state and layer 3 misses it entirely. This rule watches not the state but the
# GROWTH of the restart counter - a loop gives itself away by motion, not state.
RFILE="$STATE/.restarts"
NEW=""; LOOPING=""
for u in pihole unbound influxdb grafana city-air sds011 server-www; do
  N=$(systemctl --user show "$u.service" -p NRestarts --value 2>/dev/null); N=${N:-0}
  PREV=$(grep "^$u=" "$RFILE" 2>/dev/null | cut -d= -f2); PREV=${PREV:-$N}
  [ $(( N - PREV )) -ge 3 ] && LOOPING="$LOOPING $u(+$(( N - PREV )))"
  NEW="$NEW$u=$N
"
done
printf '%s' "$NEW" > "$RFILE"
say "restart loops:${LOOPING:- none}"
if [ -n "$LOOPING" ]; then
  evaluate restart_loop bad 0 alarm "A unit is restarting in a loop" \
    "Restart-counter growth over the last 5 minutes:$LOOPING
The loop is too slow for systemd to call the unit failed - layer 3 will not catch it.
Check: journalctl --user -u <unit> -n 60"
else
  evaluate restart_loop ok 0 alarm "A unit is restarting in a loop" ""
fi

# --- safety net: anything in the failed state
# The OnFailure= drop-ins are attached to specific units, but it is easy to add
# an eighth one and forget the drop-in. This rule catches any of them.
FAILED=$(systemctl --user --failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
# Same flag as in unit-failed.sh - see the comment there. Without it every
# backup run would report the very units it deliberately stopped.
MAINT_FLAG="$HOME/alerts/maintenance"
if [ -f "$MAINT_FLAG" ] && [ $(( $(date +%s) - $(stat -c %Y "$MAINT_FLAG") )) -lt 900 ]; then
  say "maintenance in progress - skipping the failed-units check"
  FAILED=""
fi
if [ -n "$FAILED" ]; then
  evaluate failed_units bad 0 alarm "A unit is in the failed state" \
    "systemd reports as failed: $FAILED
Check: systemctl --user status $FAILED"
else
  evaluate failed_units ok 0 alarm "A unit is in the failed state" ""
fi

# Is TRIM actually CONFIGURED - not merely error-free.
#
# This rule exists because the error-count rule below reported "back to normal"
# on 2026-08-30 while TRIM was in fact switched off entirely: after a reboot
# provisioning_mode reverted to "full", discard_max_bytes became 0, the kernel
# stopped issuing DISCARD at all and therefore stopped producing errors.
# Silence looked like health. Absence of errors is not evidence of function.
TRIM_MODE=$(cat /sys/class/scsi_disk/*/provisioning_mode 2>/dev/null | head -1)
TRIM_MAX=$(cat /sys/block/sda/queue/discard_max_bytes 2>/dev/null || echo 0)
say "trim: mode=${TRIM_MODE:-?} max=${TRIM_MAX:-0}"
if [ "$TRIM_MODE" != "unmap" ] || [ "${TRIM_MAX:-0}" -eq 0 ]; then
  evaluate trim_disabled bad 0 info "TRIM is switched off on the SSD" \
    "provisioning_mode=${TRIM_MODE:-unknown}, discard_max_bytes=${TRIM_MAX:-0} (expected unmap and 8388608).
Without TRIM the drive's write performance degrades and its cells wear faster,
and nothing else reports it - fstrim just says 'the discard operation is not
supported' into a log nobody reads.
Check: systemctl status ssd-trim-limit.service
       cat /sys/class/scsi_disk/*/provisioning_mode
       sudo fstrim -v /"
else
  evaluate trim_disabled ok 0 info "TRIM is switched off on the SSD" ""
fi

# Kernel-level I/O errors on the disk. These are invisible from userspace:
# "critical target error ... op 0x3:(DISCARD)" appeared on every fstrim while
# fstrim itself reported success, so TRIM had silently never worked for the
# whole life of the disk (found 2026-08-30). Anything at this level means the
# storage layer is rejecting commands and deserves a look.
KERR=$(sudo -n journalctl -k --since -24h --no-pager 2>/dev/null | grep -ci "critical target error\|I/O error\|medium error" || true)
KERR=${KERR:-0}
say "kernel i/o errors (24h): $KERR"
if [ "$KERR" -ge 5 ]; then
  evaluate kernel_target_errors bad 0 alarm "Kernel is reporting disk I/O errors" \
    "$KERR entries in the last 24h (critical target / I/O / medium error).
The disk or the USB bridge is rejecting commands. Note that fstrim and SMART can
both report success while this is happening - that is exactly how a broken TRIM
went unnoticed here for 14276 power-on hours.
Check: sudo journalctl -k --since -24h | grep -i 'critical target\|I/O error'
       cat /sys/block/sda/queue/discard_max_bytes
       sudo smartctl -a /dev/sda"
else
  evaluate kernel_target_errors ok 0 alarm "Kernel is reporting disk I/O errors" ""
fi

# --- data freshness ----------------------------------------------------------
W=$(series_age SDS011 pm25)
say "influx/sds011: $W"

if [ "$W" = ERROR ]; then
  # InfluxDB is not answering. We do NOT evaluate series freshness then - we know
  # nothing about the data, and two extra false alarms would only muddy the
  # picture.
  evaluate influxdb bad "$INFLUX_DEBOUNCE" alarm \
    "InfluxDB is not answering" \
    "Queries to $INFLUX_URL have been failing for over $(( INFLUX_DEBOUNCE / 60 )) min. The charts are frozen and nothing is being written.
Check: systemctl --user status influxdb; podman logs --tail 50 systemd-influxdb"
  say "influxdb is down - skipping freshness rules"
  exit 0
fi

evaluate influxdb ok "$INFLUX_DEBOUNCE" alarm "InfluxDB is not answering" ""

# --- local SDS011 sensor: your hardware, your fix -> alarm
if [ "$W" = NONE ] || [ "$W" -gt "$SDS011_MAX" ]; then
  evaluate sds011 bad 0 alarm \
    "SDS011 sensor has gone quiet" \
    "No new measurements $([ "$W" = NONE ] && echo "- the series is completely empty" || echo "for $(( W / 60 )) min"). Threshold: $(( SDS011_MAX / 60 )) min, the sensor writes every 10 min.
Check: systemctl --user status sds011; journalctl --user -u sds011 -n 50; ls -l /dev/ttyUSB*"
else
  evaluate sds011 ok 0 alarm "SDS011 sensor has gone quiet" ""
fi

# --- GIOS: someone else's station, nothing you can do -> quiet channel
G=$(series_age GIOS pm25)
say "influx/gios: $G"
if [ "$G" = NONE ] || [ "$G" -gt "$GIOS_MAX" ]; then
  evaluate gios bad 0 info \
    "The GIOS station is not publishing" \
    "Last measurement $([ "$G" = NONE ] && echo "does not exist - the series is empty" || echo "was $(( G / 60 )) min ago"). Threshold: $(( GIOS_MAX / 60 )) min.
This is usually the GIOS end, not this host. Check whether fetching works:
  journalctl --user -u city-air -n 20
If the log shows fresh cycles with the same 'last' value - the station is quiet and you just wait it out."
else
  evaluate gios ok 0 info "The GIOS station is not publishing" ""
fi

# One more pass at the end: notifications queued above should go out now, not
# wait for the next run.
"$NOTIFY" queue >/dev/null 2>&1
say "queue: $("$NOTIFY" status | head -1)"
exit 0
