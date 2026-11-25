#!/usr/bin/env bash
# Consistent DB snapshots + complete private/host configuration. Run deliberately.
set -euo pipefail
umask 077
DIR="$HOME/backups"
mkdir -p "$DIR"
chmod 700 "$DIR"
exec 9>"$DIR/.backup.lock"
flock -n 9 || { echo "Another backup is running." >&2; exit 1; }
NAME="malinka-$(date +%F-%H%M%S)"
OUT="$DIR/$NAME"
WORK="$DIR/.$NAME.partial"
[ ! -e "$OUT" ] && [ ! -e "$WORK" ] || { echo "Backup name already exists." >&2; exit 1; }
MAINT_FLAG="$HOME/alerts/maintenance"
UNITS=(influxdb grafana sds011 city-air telegraf)
WAS=()
STOPPED=0
restore_services() {
  local i failed=0
  for i in "${!UNITS[@]}"; do
    if [ "${WAS[$i]}" = active ]; then systemctl --user start "${UNITS[$i]}" || failed=1; fi
  done
  # Starting InfluxDB may pull in Telegraf; preserve the pre-backup state.
  for i in "${!UNITS[@]}"; do
    if [ "${WAS[$i]}" != active ]; then systemctl --user stop "${UNITS[$i]}" || failed=1; fi
  done
  for i in "${!UNITS[@]}"; do
    if [ "${WAS[$i]}" = active ] && ! systemctl --user is-active --quiet "${UNITS[$i]}"; then
      echo "Could not restore ${UNITS[$i]} after backup." >&2
      failed=1
    fi
  done
  return "$failed"
}
cleanup() {
  local status=$?
  trap - EXIT
  if [ "$STOPPED" -eq 1 ]; then
    echo "Restoring service state after interrupted backup..." >&2
    if ! restore_services; then status=1; fi
  fi
  rm -f "$MAINT_FLAG"
  if [ "$status" -ne 0 ]; then echo "Backup incomplete: $WORK (not published as successful)." >&2; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Code 1 can arise from transient alert queue/state files. Database snapshots
# below are consistent separately; this warning is not a DB-integrity guarantee.
tar_ok() {
  local status=0
  "$@" || status=$?
  if [ "$status" -gt 1 ]; then return "$status"; fi
  if [ "$status" -eq 1 ]; then echo "WARNING: some runtime files changed while archived." >&2; fi
}
for path in .config/site.conf .config/secrets sensor-app city-app unbound telegraf grafana alerts; do
  [ -e "$HOME/$path" ] || { echo "Required backup path missing: $path" >&2; exit 1; }
done
sudo -n true
if podman exec pihole pgrep -f 'pihole -g|gravity' >/dev/null 2>&1; then
  echo "Gravity update in progress; retry later." >&2; exit 1
fi
FREE=$(df --output=avail -m "$HOME" | tail -1)
[ "$FREE" -gt 2000 ] || { echo "Not enough free space for backup." >&2; exit 1; }
mkdir -m 700 "$WORK"
for unit in "${UNITS[@]}"; do
  if systemctl --user is-active --quiet "$unit"; then WAS+=(active); else WAS+=(inactive); fi
done
mkdir -p "$(dirname "$MAINT_FLAG")"
touch "$MAINT_FLAG"
STOPPED=1
systemctl --user stop grafana influxdb
podman volume export grafana-data -o "$WORK/grafana-data.tar"
podman volume export influxdb-data -o "$WORK/influxdb-data.tar"
restore_services
STOPPED=0
# Pi-hole stays online. SQLite's backup API produces a consistent gravity DB.
SQL_DEST=${WORK//\'/\'\'}
sudo sqlite3 "$HOME/pihole/etc-pihole/gravity.db" ".backup '$SQL_DEST/gravity.db'"
[ "$(sudo sqlite3 "$WORK/gravity.db" 'PRAGMA quick_check;')" = ok ] || { echo "Gravity snapshot failed integrity check." >&2; exit 1; }
sudo chown "$(id -u):$(id -g)" "$WORK/gravity.db"
tar_ok sudo tar -czf "$WORK/pihole-conf.tar.gz" --exclude='pihole-FTL.db*' \
  --exclude='gravity.db*' --exclude='gravity_old.db*' -C "$HOME" pihole
sudo chown "$(id -u):$(id -g)" "$WORK/pihole-conf.tar.gz"
CANDIDATES=(install.sh LICENSE sensor-app city-app unbound telegraf alerts grafana .githooks examples \
  healthcheck.sh backup.sh notify.sh .gitignore README.md RECOVERY.md rebuild-images.sh nucleo-bridge.py host tools macbook \
  .config/containers/systemd .config/systemd/user .config/secrets .config/site.conf .config/alerts.conf .ssh)
PACK=()
for path in "${CANDIDATES[@]}"; do
  if [ -e "$HOME/$path" ]; then PACK+=("$path"); else echo "WARNING: optional backup path missing: $path" >&2; fi
done
tar_ok tar -czf "$WORK/app-and-quadlets.tar.gz" --exclude=__pycache__ --exclude='*.backup-*' \
  --exclude=alerts/maintenance -C "$HOME" "${PACK[@]}"
SYS_CANDIDATES=(etc/systemd/journald.conf.d etc/apt/apt.conf.d/52unattended-upgrades-local \
  etc/systemd/system/sysstat-collect.timer.d etc/default/sysstat etc/sysstat/sysstat etc/smartd.conf \
  etc/udev/rules.d/60-jms578-trim.rules etc/systemd/system/ssd-trim-limit.service usr/local/sbin/ssd-trim-limit.sh \
  etc/systemd/system.conf.d/watchdog.conf etc/nsswitch.conf etc/cloud/cloud-init.disabled \
  etc/modprobe.d/disable-sound.conf etc/sysctl.d/podman-ports.conf etc/sysctl.d/99-tuning.conf etc/sysctl.d/99-tailscale.conf \
  boot/firmware/config.txt etc/subuid etc/subgid)
SYS_PACK=()
for path in "${SYS_CANDIDATES[@]}"; do
  if [ -e "/$path" ]; then SYS_PACK+=("$path"); else echo "WARNING: optional host path missing: /$path" >&2; fi
done
tar_ok sudo tar -czf "$WORK/etc.tar.gz" -C / "${SYS_PACK[@]}"
sudo chown "$(id -u):$(id -g)" "$WORK/etc.tar.gz"
crontab -l > "$WORK/crontab-user.txt" 2>/dev/null || true
id > "$WORK/user-identity.txt"
dpkg-query -W > "$WORK/packages.txt"
for file in "$WORK"/*.tar*; do tar -tf "$file" >/dev/null; done
# SUCCESS exists only inside the private partial directory until final rename.
date +%s > "$WORK/SUCCESS"
(cd "$WORK" && sha256sum ./*.tar* gravity.db crontab-user.txt user-identity.txt packages.txt SUCCESS > SHA256SUMS)
(cd "$WORK" && sha256sum -c SHA256SUMS)
chmod 600 "$WORK"/*
mv "$WORK" "$OUT"
printf 'BACKUP_NAME=%s\nDone: %s\n' "$NAME" "$OUT"
