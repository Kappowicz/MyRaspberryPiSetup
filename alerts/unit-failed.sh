#!/bin/bash
# Called by systemd (OnFailure=) when a unit enters the failed state.
# Restart=always hides crashes on its own: the container comes back up over and
# over and nobody knows. Only exhausting StartLimitBurst produces a failed
# state - and that is what fires this.
set -u
U="${1:-unknown}"

# Planned maintenance is not a failure. backup.sh DELIBERATELY stops influxdb
# and grafana, and Requires= drags city-air and sds011 down with them - systemd
# then tries to bring them up without the database, exhausts the restart limit
# and marks them failed. On 2026-08-30 that produced 106 false alarms in a
# single afternoon.
#
# The flag has an expiry: if a backup dies halfway through and never clears it,
# alarms get their voice back after 15 minutes. Silence with no expiry is the
# surest way to lose alerting for good without noticing.
FLAG="$HOME/alerts/maintenance"
if [ -f "$FLAG" ]; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$FLAG") ))
  if [ "$AGE" -lt 900 ]; then
    logger -t alert-maintenance "skipping alarm for $U - planned maintenance in progress (${AGE}s)"
    exit 0
  fi
fi

TAIL=$(journalctl --user -u "$U" -n 12 --no-pager -o cat 2>/dev/null | tail -8)
exec "$HOME/notify.sh" alarm "Unit failed: $U" \
"systemd marked the unit as failed: it either died on startup,
or exhausted its restart limit (5 attempts in 5 minutes).

Last lines from the log:
$TAIL

Inspect: systemctl --user status $U
Recover:  systemctl --user reset-failed $U && systemctl --user start $U"
