#!/bin/bash
# Bootstrap script: sets up this configuration on a clean system.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== 1/8 creating directories =="
mkdir -p "$HOME/.config/secrets" && chmod 700 "$HOME/.config/secrets"
mkdir -p "$HOME/.config/containers/systemd"
mkdir -p "$HOME/.config/systemd/user"
mkdir -p "$HOME/alerts/state" "$HOME/alerts/queue"
mkdir -p "$HOME/backups"
mkdir -p "$HOME/telegraf" 

echo "== 2/8 copying secret templates (without overwriting existing ones) =="
if [ -d "$PROJECT_DIR/examples/secrets" ]; then
  for f in "$PROJECT_DIR"/examples/secrets/*.example; do
    [ -e "$f" ] || continue
    name="$(basename "${f%.example}")"
    target="$HOME/.config/secrets/$name"
    if [ ! -f "$target" ]; then
      cp "$f" "$target"
      chmod 600 "$target"
      echo "   created: $target (FILL IN THE VALUES!)"
    else
      echo "   exists: $target (skipping)"
    fi
  done
fi

if [ -f "$PROJECT_DIR/telegraf/telegraf.conf" ] && [ ! -f "$HOME/telegraf/telegraf.conf" ]; then
  cp "$PROJECT_DIR/telegraf/telegraf.conf" "$HOME/telegraf/telegraf.conf"
  echo "   created: $HOME/telegraf/telegraf.conf"
fi

if [ -d "$PROJECT_DIR/telegraf/scripts" ] && [ ! -d "$HOME/telegraf/scripts" ]; then
  cp -r "$PROJECT_DIR/telegraf/scripts" "$HOME/telegraf/scripts"
  echo "   created: $HOME/telegraf/scripts"
fi

echo "== 3/8 site configuration ==" 
SITE="$HOME/.config/site.conf"
if [ ! -f "$SITE" ]; then
  cp "$PROJECT_DIR/examples/site.conf.example" "$SITE"
  chmod 600 "$SITE"
  echo "   created: $SITE (EDIT IT: station id, org, bucket, location tags)"
else
  echo "   exists: $SITE (skipping)"
fi
# shellcheck disable=SC1090
. "$SITE"

# The Grafana dashboard filters on the location tags, so it is rendered from a
# template rather than shipped with one house's labels baked in.
DASH_IN="$PROJECT_DIR/grafana/dashboards/air-quality.json.in"
if [ -f "$DASH_IN" ]; then
  sed -e "s|__BUCKET__|${INFLUXDB_BUCKET}|g" \
      -e "s|__LOC_HOME__|${SENSOR_LOCATION}|g" \
      -e "s|__LOC_CITY__|${LOCATION}|g" \
      "$DASH_IN" > "${DASH_IN%.in}"
  echo "   rendered: ${DASH_IN%.in}"
fi

echo "== 4/8 host hardware & power tuning (Wi-Fi, Bluetooth, Audio) =="
CONFIG_TXT="/boot/firmware/config.txt"
if [ -w "$CONFIG_TXT" ] || sudo -n true 2>/dev/null; then
  SUDO=""
  [ -w "$CONFIG_TXT" ] || SUDO="sudo"

  if ! grep -q "dtoverlay=disable-wifi" "$CONFIG_TXT" 2>/dev/null; then
    $SUDO tee -a "$CONFIG_TXT" >/dev/null << 'CFG'

# Disable onboard Wi-Fi and Bluetooth
dtoverlay=disable-wifi
dtoverlay=disable-bt
CFG
    echo "   added: disable-wifi and disable-bt overlays to $CONFIG_TXT"
  else
    echo "   exists: disable-wifi in $CONFIG_TXT (skipping)"
  fi

  if grep -q "^dtparam=audio=on" "$CONFIG_TXT" 2>/dev/null; then
    $SUDO sed -i 's/^dtparam=audio=on/dtparam=audio=off/' "$CONFIG_TXT"
    echo "   disabled: dtparam=audio in $CONFIG_TXT"
  fi

  MODPROBE_SOUND="/etc/modprobe.d/disable-sound.conf"
  if [ ! -f "$MODPROBE_SOUND" ]; then
    $SUDO tee "$MODPROBE_SOUND" >/dev/null << 'CFG'
# Disable sound drivers on headless server
blacklist snd
blacklist snd_pcm
blacklist snd_timer
blacklist snd_soc_core
blacklist snd_soc_hdmi_codec
blacklist snd_bcm2835
CFG
    echo "   created: $MODPROBE_SOUND"
  fi

  $SUDO systemctl disable --now bluetooth.service wpa_supplicant.service alsa-restore.service 2>/dev/null || true
else
  echo "   skipping host config.txt tuning (no sudo access)"
fi

echo "== 5/8 enabling linger for user $USER =="
# Linger lets the user's services run in the background after logout and across
# reboots. Without it the whole stack is dead after a restart and nothing says so.
loginctl enable-linger "$USER" 2>/dev/null || echo "   note: loginctl linger needs privileges or an active session"

echo "== 6/8 git configuration (if the repository is initialised) =="
if [ -d "$PROJECT_DIR/.git" ]; then
  git config core.hooksPath .githooks
  echo "   pre-commit hook active (.githooks)"
fi

echo "== 7/8 reloading and starting systemd units =="
systemctl --user daemon-reload
systemctl --user enable --now alerts.timer heartbeat.timer daily-check.timer image-check.timer boot-notify.service 2>/dev/null || true

echo "== 8/8 done =="
cat << 'INFO'

Installation finished.

Next steps:
1. Fill in the secrets in: ~/.config/secrets/*.env
   and your own values in: ~/.config/site.conf
2. Create the volumes for InfluxDB and Grafana:
     podman volume create influxdb-data
     podman volume create grafana-data
3. Build the local application images (they have dependencies baked in so the
   containers start without network access):
     podman build -t localhost/city-air:latest ~/city-app
     podman build -t localhost/sds011:latest  ~/sensor-app
4. Once the Pi-hole container is running, load the blocklists and rules:
     ~/pihole/load-rules.sh
5. Check the state of the whole system:
     ~/healthcheck.sh
INFO
