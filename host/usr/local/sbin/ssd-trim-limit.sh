#!/bin/bash
# Sets a UNMAP size the JMS578 bridge actually accepts, and verifies the result.
# Silently doing nothing is the failure mode this whole setup exists to avoid,
# so the script is loud when it cannot do its job.
set -u
DISK=/sys/block/sda/queue
LIMIT=8388608

MODE=$(cat /sys/class/scsi_disk/*/provisioning_mode 2>/dev/null | head -1)
if [ "$MODE" != "unmap" ]; then
  echo "provisioning_mode is '$MODE', not 'unmap' - udev rule did not apply; TRIM stays off" >&2
  exit 1
fi

HW=$(cat "$DISK/discard_max_hw_bytes" 2>/dev/null || echo 0)
if [ "${HW:-0}" -eq 0 ]; then
  echo "discard_max_hw_bytes is 0 - the kernel reports no discard support" >&2
  exit 1
fi

echo "$LIMIT" > "$DISK/discard_max_bytes" || { echo "write to discard_max_bytes rejected" >&2; exit 1; }
GOT=$(cat "$DISK/discard_max_bytes")
[ "$GOT" = "$LIMIT" ] || { echo "discard_max_bytes is $GOT, expected $LIMIT" >&2; exit 1; }
echo "TRIM enabled: provisioning_mode=unmap, discard_max_bytes=$GOT"
