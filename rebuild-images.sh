#!/bin/bash
# Rebuild the local city-air and sds011 images.
#
# Dependencies are baked into the image so the containers can start without
# network access (see Containerfile). The price: the image stops receiving
# patches from python:3.11-slim. This script pulls a fresh base image and
# rebuilds both.
#
# Run it DELIBERATELY - it restarts the dust sensor and the GIOS fetcher.
# Intentionally not wired to a timer: the `local_images` rule in layer 5 tells
# you when the images are going stale, and you decide when to rebuild.
set -euo pipefail

echo "== 1/3 fresh base image =="
podman pull docker.io/library/python:3.11-slim | tail -1

echo "== 2/3 rebuild =="
podman build -q -t localhost/city-air:latest "$HOME/city-app" >/dev/null
podman build -q -t localhost/sds011:latest  "$HOME/sensor-app" >/dev/null
podman images --format "{{.Repository}}:{{.Tag}} {{.Created}}" | grep localhost | sed 's/^/   /'

echo "== 3/3 restart and verify =="
systemctl --user restart city-air sds011
sleep 25
FAILED=0
for u in city-air sds011; do
  S=$(systemctl --user is-active "$u")
  printf '   %-9s %s\n' "$u" "$S"
  [ "$S" = active ] || FAILED=1
done
# "active" alone is not enough - a container can be alive and doing nothing.
podman run --rm --network none localhost/city-air:latest python -c "import influxdb_client" \
  && echo "   imports without network: OK" || { echo "   imports without network: FAILED"; FAILED=1; }
[ "$FAILED" = 0 ] || { echo "!! something did not come up - check journalctl --user -u city-air -u sds011"; exit 1; }
echo "Done."
