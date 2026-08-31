#!/bin/bash
# Read the temperature (raw value, e.g. 45123)
RAW_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp)

# Convert to a human-readable format (e.g. 45.1)
TEMP=$(awk -v val=$RAW_TEMP 'BEGIN { print val / 1000 }')

# Write a JSON file into the site directory
echo "{\"temperature\": \"$TEMP\"}" > "$HOME/sample-site/temp.json"
