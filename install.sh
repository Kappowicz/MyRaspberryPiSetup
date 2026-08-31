#!/bin/bash
# Bootstrap script: sets up this configuration on a clean system.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== 1/7 creating directories =="
mkdir -p "$HOME/.config/secrets" && chmod 700 "$HOME/.config/secrets"
mkdir -p "$HOME/.config/containers/systemd"
mkdir -p "$HOME/.config/systemd/user"
mkdir -p "$HOME/alerts/state" "$HOME/alerts/queue"
mkdir -p "$HOME/backups"

echo "== 2/7 copying secret templates (without overwriting existing ones) =="
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

echo "== 3/7 site configuration =="
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

echo "== 4/7 enabling linger for user $USER =="
# Linger lets the user's services run in the background after logout and across
# reboots. Without it the whole stack is dead after a restart and nothing says so.
loginctl enable-linger "$USER" 2>/dev/null || echo "   note: loginctl linger needs privileges or an active session"

echo "== 5/7 git configuration (if the repository is initialised) =="
if [ -d "$PROJECT_DIR/.git" ]; then
  git config core.hooksPath .githooks
  echo "   pre-commit hook active (.githooks)"
fi

echo "== 6/7 reloading and starting systemd units =="
systemctl --user daemon-reload
systemctl --user enable --now alerts.timer heartbeat.timer daily-check.timer 2>/dev/null || true

echo "== 7/7 done =="
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
