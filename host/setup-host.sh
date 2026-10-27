#!/usr/bin/env bash
# Run deliberately on Raspberry Pi OS/Debian. No service changes during file staging.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
TARGET_USER="${1:?Usage: sudo host/setup-host.sh <user> [--headless]}"
HEADLESS="${2:-}"
case "$HEADLESS" in ''|--headless) ;; *) echo "Unknown option: $HEADLESS" >&2; exit 2 ;; esac
getent passwd "$TARGET_USER" >/dev/null
[ -f /proc/device-tree/model ] && grep -q 'Raspberry Pi 5' /proc/device-tree/model || { echo "This hardware profile is for Raspberry Pi 5." >&2; exit 1; }
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAVE="/var/backups/malinka-host/$(date +%Y%m%d%H%M%S)"
mkdir -p "$SAVE"
chmod 700 "$SAVE"
copy() {
  local relative="$1"
  if [ -e "/$relative" ]; then mkdir -p "$SAVE/$(dirname "$relative")"; cp -a "/$relative" "$SAVE/$relative"; fi
  install -D -m 644 "$BASE/$relative" "/$relative"
}
for path in etc/sysctl.d/podman-ports.conf etc/sysctl.d/99-tuning.conf etc/systemd/system.conf.d/watchdog.conf \
    etc/systemd/journald.conf.d/90-persistent.conf etc/apt/apt.conf.d/52unattended-upgrades-local \
    etc/systemd/system/sysstat-collect.timer.d/override.conf etc/default/sysstat etc/sysstat/sysstat etc/smartd.conf \
    etc/udev/rules.d/60-jms578-trim.rules etc/systemd/system/ssd-trim-limit.service usr/local/sbin/ssd-trim-limit.sh; do copy "$path"; done
chmod 755 /usr/local/sbin/ssd-trim-limit.sh
usermod -aG dialout,video "$TARGET_USER"
sysctl --system
BOOT=/boot/firmware/config.txt
cp -a "$BOOT" "$SAVE/config.txt"
if ! grep -q '^dtparam=watchdog=on$' "$BOOT"; then printf '\n[all]\ndtparam=watchdog=on\n' >> "$BOOT"; fi
if [ "$HEADLESS" = --headless ]; then
  copy etc/modprobe.d/disable-sound.conf
  # Explicit because cutting Wi-Fi on a remotely reached machine can lose access.
  for overlay in disable-wifi disable-bt; do
    if ! grep -q "^dtoverlay=$overlay$" "$BOOT"; then printf '\n[all]\ndtoverlay=%s\n' "$overlay" >> "$BOOT"; fi
  done
  sed -i 's/^dtparam=audio=on$/dtparam=audio=off/' "$BOOT"
  systemctl disable --now bluetooth.service wpa_supplicant.service alsa-restore.service
fi
systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger --subsystem-match=scsi_disk
udevadm settle
systemctl enable NetworkManager-wait-online.service
systemctl enable --now ssd-trim-limit.service smartmontools.service sysstat.service sysstat-collect.timer sysstat-summary.timer apt-daily.timer apt-daily-upgrade.timer
echo "Host configured. Previous files: $SAVE. Log in again for groups; reboot later for boot/watchdog settings."
