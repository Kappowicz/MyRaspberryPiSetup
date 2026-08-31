#!/bin/sh
# No "pip install" here - dependencies already live in the image (see
# Containerfile). That is what lets the container start with no network
# and no access to PyPI.
echo "Starting GIOS air quality fetcher..."
exec python -u /app/main.py
