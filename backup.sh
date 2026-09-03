#!/bin/bash
# Emergency backup - phase 0 of the plan, revised 2026-08-29.
#
# Beyond the version in the plan this also covers: application code
# (~/sensor-app, ~/city-app - 56 KB that no script can regenerate),
# ~/unbound/unbound.conf, the /etc configuration created on 29.08 (journald,
# apt, sysstat, smartd) and the user crontab. The plan copied none of those.
#
# Safeguards added after testing:
#  - tar returns 1 when a file changes while being read (verified) - under
#    "set -e" that would kill the script halfway, so exit code 1 is tolerated
#    and only 2 or higher is treated as a real error
#  - the trap brings Grafana and InfluxDB back even if the script dies between
#    stopping and starting them
#  - it refuses to run while a gravity update is in progress (Sundays 04:10),
#    because the database is being rewritten then and the copy would be
#    inconsistent
set -euo pipefail

DIR="$HOME/backups"
D=$(date +%F-%H%M%S)
OUT="$DIR/malinka-$D"

# influxdb has RequiredBy=city-air.service sds011.service, and Requires=
# PROPAGATES a stop - stopping the database drags the dust sensor and the GIOS
# fetcher down with it. The version in the plan restarted only the database and
# Grafana, so those two stayed off silently. Hence: remember what was running
# and restore exactly that.
UNITS="grafana influxdb sds011 city-air"
WAS=""
RESTART=0
# The flag tells the alerting system that stopping these services is intended.
# Cleared by the trap even if the script dies halfway.
MAINT_FLAG="$HOME/alerts/maintenance"
cleanup(){
  rm -f "$MAINT_FLAG"
  if [ "$RESTART" = 1 ]; then
    echo "!! script interrupted with services stopped - restoring"
    systemctl --user start influxdb 2>/dev/null || true
    [ -n "$WAS" ] && systemctl --user start $WAS 2>/dev/null || true
  fi
}
trap cleanup EXIT

# tar exit 1 = warning (a file changed), exit >=2 = a real error
tar_ok(){
  local rc=0
  "$@" || rc=$?
  [ "$rc" -le 1 ] || { echo "   tar ERROR (code $rc)"; return "$rc"; }
  [ "$rc" -eq 1 ] && echo "   (warning: a file changed while reading; the archive is complete)"
  return 0
}

echo "== 0/5 pre-flight =="
if podman exec pihole pgrep -f "pihole -g|gravity" >/dev/null 2>&1; then
  echo "   A gravity update is running. Abort and try later."; exit 1
fi
FREE=$(df --output=avail -m /home | tail -1)
[ "$FREE" -gt 2000 ] || { echo "   Not enough space: ${FREE} MB"; exit 1; }
echo "   free: ${FREE} MB, gravity is not running"
mkdir -p "$OUT"
chmod 700 "$DIR" "$OUT"   # the archives carry secrets - no read access for others

echo "== 1/5 volumes (services stopped) =="
# Grafana and InfluxDB keep state in SQLite. A copy of a live database file
# looks fine and only falls apart on restore - i.e. at the worst possible moment.
for u in $UNITS; do systemctl --user is-active --quiet "$u" && WAS="$WAS $u"; done
echo "   running before the backup:$WAS"
mkdir -p "$(dirname "$MAINT_FLAG")" && touch "$MAINT_FLAG"
RESTART=1
systemctl --user stop grafana influxdb
podman volume export grafana-data  -o "$OUT/grafana-data.tar"
podman volume export influxdb-data -o "$OUT/influxdb-data.tar"
# influxdb first, because the rest depends on it
systemctl --user start influxdb
[ -n "$WAS" ] && systemctl --user start $WAS
RESTART=0

echo "== 2/5 Pi-hole configuration =="
# The query database (293 MB) and the old gravity are skipped - they rebuild
# themselves.
tar_ok sudo tar czf "$OUT/pihole-conf.tar.gz" \
  --exclude="pihole-FTL.db*" --exclude="gravity_old.db" -C "$HOME" pihole
sudo chown user:user "$OUT/pihole-conf.tar.gz"

echo "== 3/5 application code, unbound, quadlets, alerting, secrets =="
# Extended 2026-08-30. The previous version took only application code and
# quadlets. Once secrets moved out of the quadlets into ~/.config/secrets, a
# restore from such a copy brought services up WITHOUT database access: the
# EnvironmentFile= files did not exist. The whole of ~/alerts and the systemd
# units were missing too - and notifications do not regenerate themselves.
#
# Everything comes from a single -C "$HOME", so paths inside the archive are
# unambiguous. Previously ".config/containers/systemd" landed as "systemd/" and
# would have collided with ".config/systemd/user" once a second directory was
# added.
CANDIDATES="install.sh LICENSE sensor-app city-app unbound alerts grafana .githooks examples previous-versions
healthcheck.sh backup.sh notify.sh .gitignore README.md PLAN.md rebuild-images.sh
.config/containers/systemd .config/systemd/user .config/secrets .config/alerts.conf"
TO_PACK=""
MISSING=""
for k in $CANDIDATES; do
  if [ -e "$HOME/$k" ]; then TO_PACK="$TO_PACK $k"; else MISSING="$MISSING $k"; fi
done
# A missing entry must be LOUD. tar exits 2 on a non-existent path and "set -e"
# would kill the whole script, so the list is filtered by existence - but a
# silent filter hides renames: on 2026-08-30 the whole ~/alerts directory
# dropped out of the backup because the list still said "alerty", and nothing
# said a word.
[ -n "$MISSING" ] && echo "   !! WARNING: listed but missing (NOT backed up):$MISSING"
echo "   packing:$(echo $TO_PACK | wc -w) entries"
# shellcheck disable=SC2086
# __pycache__ is generated bytecode and the maintenance flag is transient -
# neither belongs in a backup or in the repository.
tar_ok tar czf "$OUT/app-and-quadlets.tar.gz" \
  --exclude="__pycache__" --exclude="alerts/maintenance" \
  -C "$HOME" $TO_PACK

echo "== 4/5 system configuration =="
# Same existence filter and same loud warning as above: a rename or a deleted
# file must not shrink the backup in silence. Added 2026-08-30 - the TRIM fix,
# the watchdog and the winbind change all live outside $HOME and were not
# covered before, so a restore would have quietly lost them.
SYS_CANDIDATES="/etc/systemd/journald.conf.d
/etc/apt/apt.conf.d/52unattended-upgrades-local
/etc/systemd/system/sysstat-collect.timer.d
/etc/default/sysstat /etc/sysstat/sysstat /etc/smartd.conf
/etc/udev/rules.d/60-jms578-trim.rules
/etc/systemd/system/ssd-trim-limit.service
/usr/local/sbin/ssd-trim-limit.sh
/etc/systemd/system.conf.d/watchdog.conf
/etc/nsswitch.conf
/etc/cloud/cloud-init.disabled"
SYS_PACK=""
SYS_MISSING=""
for k in $SYS_CANDIDATES; do
  if [ -e "$k" ]; then SYS_PACK="$SYS_PACK $k"; else SYS_MISSING="$SYS_MISSING $k"; fi
done
[ -n "$SYS_MISSING" ] && echo "   !! WARNING: listed but missing (NOT backed up):$SYS_MISSING"
echo "   system files:$(echo $SYS_PACK | wc -w) entries"
# shellcheck disable=SC2086
tar_ok sudo tar czf "$OUT/etc.tar.gz" $SYS_PACK
sudo chown user:user "$OUT/etc.tar.gz"
crontab -l > "$OUT/crontab-user.txt" 2>/dev/null || true

echo "== 5/5 verification =="
BAD=0
chmod 600 "$OUT"/*.tar* 2>/dev/null || true
for f in "$OUT"/*.tar*; do
  printf "   %-26s " "$(basename "$f")"
  if tar tf "$f" >/dev/null 2>&1; then echo "OK ($(du -h "$f" | cut -f1))"; else echo "CORRUPT"; BAD=1; fi
done
printf "   services after backup:"; for u in $UNITS; do printf " %s=%s" "$u" "$(systemctl --user is-active $u)"; done; echo
[ "$BAD" = 0 ] || { echo "   At least one archive is corrupt."; exit 1; }

cat <<INFO

Done: $OUT

This copy sits on the same disk as the original, so it protects against your own
mistake, not against an SSD failure. Pull it to the laptop:
  rsync -av $(whoami)@$(hostname -I | cut -d' ' -f1):backups/malinka-$D ~/malinka-backups/

NOTE: the archive contains secrets in cleartext (InfluxDB tokens and passwords).
After rotating secrets, take a fresh copy - the old one restores credentials
that are already revoked.
INFO
