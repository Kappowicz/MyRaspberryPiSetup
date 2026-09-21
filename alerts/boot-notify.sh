#!/bin/bash
# Send a notification after boot.
# Runs once per reboot (flag file in tmpfs /run/user/1000/).
set -u

FLAG="/run/user/$(id -u)/boot-notified"
[ -f "$FLAG" ] && exit 0
touch "$FLAG"

# Give network and services a few seconds to settle before sending
sleep 15

NOTIFY="$HOME/notify.sh"
[ -x "$NOTIFY" ] || exit 0

BOOT_TIME=$(who -b 2>/dev/null | awk '{print $3, $4}')
UPTIME=$(uptime -p 2>/dev/null || uptime)
TEMP=$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2)
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
KERNEL=$(uname -r)

# Check how the previous session ended
PREV_LOG=$(journalctl -b -1 -n 1 --no-pager -o cat 2>/dev/null | tail -1)
if [[ "$PREV_LOG" =~ (Journal stopped|systemd-shutdown) ]]; then
  SHUTDOWN_TYPE="clean shutdown / reboot"
else
  SHUTDOWN_TYPE="unclean shutdown or power loss"
fi

"$NOTIFY" info "Host started (boot)" \
"Host $(hostname) is up.
Boot time:    ${BOOT_TIME:-unknown}
Uptime:       ${UPTIME}
IP:           ${IP:-unknown}
Kernel:       ${KERNEL}
Temperature:  ${TEMP:-unknown}
Previous:     ${SHUTDOWN_TYPE}"
