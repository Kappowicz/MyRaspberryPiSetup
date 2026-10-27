#!/usr/bin/env bash
# Prepare files by default. Privileged configuration and service startup are explicit.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES=0 HOST_SETUP=0 START=0
for arg in "$@"; do
  case "$arg" in
    --packages) PACKAGES=1 ;;
    --host) HOST_SETUP=1 ;;
    --start) START=1 ;;
    *) echo "Usage: install.sh [--packages] [--host] [--start]" >&2; exit 2 ;;
  esac
done
FAILED=()
report() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ] || [ "${#FAILED[@]}" -gt 0 ]; then
    echo "Setup incomplete; fix the errors above and rerun." >&2
    if [ "${#FAILED[@]}" -gt 0 ]; then printf 'FAILED: %s\n' "${FAILED[@]}" >&2; fi
    exit 1
  fi
  if [ "$START" -eq 1 ]; then echo "Setup and service startup succeeded."
  else echo "Files prepared. Restore secrets/data, then run ./install.sh --start. See RECOVERY.md."; fi
}
trap report EXIT
if [ "$PACKAGES" -eq 1 ]; then
  sudo apt-get update
  sudo apt-get install -y git arp-scan bind9-dnsutils curl ethtool jq mtr-tiny \
    nftables openssl podman crun uidmap passt python3 rsync smartmontools \
    sqlite3 sysstat tcpdump tree unattended-upgrades util-linux shellcheck raspi-utils-core
fi
command -v python3 >/dev/null || { echo "python3 is required; install packages first." >&2; exit 1; }
# Copy the whole declared configuration, including application code. Back up changed
# destinations; do not copy private runtime directories or delete existing files.
python3 "$PROJECT_DIR/tools/install-files.py" "$PROJECT_DIR" "$HOME"
mkdir -p "$HOME/.config/secrets" "$HOME/alerts/state" "$HOME/alerts/queue" "$HOME/backups"
chmod 700 "$HOME/.config/secrets" "$HOME/backups"
for example in "$PROJECT_DIR"/examples/secrets/*.example; do
  target="$HOME/.config/secrets/$(basename "${example%.example}")"
  if [ ! -e "$target" ]; then install -m 600 "$example" "$target"; fi
done
if [ ! -e "$HOME/.config/site.conf" ]; then
  install -m 600 "$PROJECT_DIR/examples/site.conf.example" "$HOME/.config/site.conf"
fi
python3 "$HOME/tools/render-dashboards.py" "$HOME"
if [ -d "$PROJECT_DIR/.git" ]; then git -C "$PROJECT_DIR" config --local core.hooksPath "$PROJECT_DIR/.githooks"; fi
if [ "$HOST_SETUP" -eq 1 ]; then sudo bash "$HOME/host/setup-host.sh" "$(id -un)"; fi
if [ "$START" -eq 0 ]; then exit 0; fi
# No service changes before configuration passes validation.
python3 "$HOME/tools/validate-config.py" "$HOME"
command -v podman >/dev/null || { echo "podman is missing; run --packages first." >&2; exit 1; }
[ "$(podman info --format '{{.Host.CgroupsVersion}}')" = v2 ] || { echo "Quadlet requires cgroup v2." >&2; exit 1; }
[ "$(podman info --format '{{.Host.OCIRuntime.Name}}')" = crun ] || { echo "crun is required for GroupAdd=keep-groups." >&2; exit 1; }
for group in dialout video; do
  id -nG | tr ' ' '\n' | grep -Fxq "$group" || { echo "Missing active group $group; run --host and log in again." >&2; exit 1; }
done
[ -r /dev/serial/by-id/usb-1a86_USB_Serial-if00-port0 ] || { echo "SDS011 USB device is missing/unreadable." >&2; exit 1; }
[ "$(/usr/sbin/sysctl -n net.ipv4.ip_unprivileged_port_start)" -le 53 ] || { echo "DNS port 53 requires host setup (--host)." >&2; exit 1; }
loginctl enable-linger "$(id -un)"
[ "$(loginctl show-user "$(id -un)" -p Linger --value)" = yes ] || { echo "Linger is not enabled." >&2; exit 1; }
# Resolve/pull images before starting anything; the definitions pin registry digests.
while IFS= read -r image; do
  if ! podman image exists "$image"; then podman pull "$image"; fi
done < <(awk -F= '/^Image=docker.io\// {print $2}' "$HOME"/.config/containers/systemd/*.container)
for volume in influxdb-data grafana-data; do podman volume exists "$volume" || podman volume create "$volume"; done
for app in city-app sensor-app; do
  name=city-air; [ "$app" = sensor-app ] && name=sds011
  if ! podman image exists "localhost/$name:latest"; then podman build -t "localhost/$name:latest" "$HOME/$app"; fi
done
systemctl --user daemon-reload
systemctl --user start unbound pihole influxdb grafana city-air sds011 telegraf
for unit in unbound pihole influxdb grafana city-air sds011 telegraf; do
  if ! systemctl --user is-active --quiet "$unit"; then FAILED+=("$unit is not active"); fi
done
if [ "${#FAILED[@]}" -gt 0 ]; then exit 1; fi
systemctl --user enable --now alerts.timer heartbeat.timer daily-check.timer image-check.timer boot-notify.service
