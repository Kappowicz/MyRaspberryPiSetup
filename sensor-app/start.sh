#!/bin/sh
# No "pip install" here - dependencies already live in the image (see
# Containerfile). That is what lets the container start with no network
# and no access to PyPI.
echo "Starting sensor application..."
# The -u (unbuffered) flag matters: without it logs do not show up in
# 'podman logs' until the buffer flushes.
exec python -u /app/main.py
