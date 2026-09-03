#!/bin/bash
# Health check for the changes made on 2026-08-29. Run it after a day of
# observation:
#   ./healthcheck.sh
# Everything here is read-only - it changes nothing.
#
# The address is detected automatically so the script keeps working after a
# renumbering and on a different machine. Override with:
#   HOST_IP=1.2.3.4 ./healthcheck.sh
P="${HOST_IP:-$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)}"
ok(){ printf "  \033[32mOK\033[0m   %s\n" "$1"; }
bad(){ printf "  \033[31mWARN\033[0m %s\n" "$1"; }

echo "== SERVICES =="
for s in pihole unbound influxdb grafana sds011 city-air telegraf; do
  [ "$(systemctl --user is-active $s.service 2>/dev/null)" = active ] \
    && ok "$s" || bad "$s NOT RUNNING"
done

echo "== DNS =="
[ -n "$(dig +short +time=3 @$P example.com A)" ] && ok "name resolution" || bad "no answer"
[ "$(dig +short @$P doubleclick.net A)" = "0.0.0.0" ] && ok "ad blocking" || bad "blocking is not working"
# Only meaningful if your router hands out a DHCP search suffix.
[ -f "$HOME/.config/site.conf" ] && . "$HOME/.config/site.conf"
if [ -n "${DHCP_SEARCH_SUFFIX:-}" ]; then
  dig @$P wpad.$DHCP_SEARCH_SUFFIX A 2>/dev/null | grep -q NXDOMAIN \
    && ok "DHCP suffix workaround" || bad "suffix workaround is not working"
fi
dig @$P cloudflare.com A 2>/dev/null | grep -q "flags:.* ad" && ok "DNSSEC validates (ad flag)" || bad "no DNSSEC validation"
dig @$P sigfail.verteiltesysteme.net A 2>/dev/null | grep -q SERVFAIL && ok "DNSSEC rejects a bad signature" || bad "a bad signature was accepted"

echo "== UPSTREAM ENCRYPTION =="
# The host's own addresses have to be excluded: pasta (podman's network stack)
# forwards container queries to the host's own address on port 53, i.e. to the
# Pi-hole next door.
# That is a local loop, not cleartext egress - the old test counted it as a
# failure.
SELF=$(ip -o -4 addr show scope global | awk "{print \$4}" | cut -d/ -f1 | tr "\n" "|")127.0.0.1
P53=$(sudo ss -tunp state established 2>/dev/null | awk "{print \$5}" | grep -E ":53$" | grep -vcE "^(${SELF})")
[ "$P53" -eq 0 ] && ok "zero connections to a remote port 53" || bad "$P53 cleartext connections!"
podman exec pihole sh -c "grep forwarded /var/log/pihole/pihole.log | tail -200 | grep -cv \"127.0.0.1#5335\"" 2>/dev/null \
  | grep -q "^0$" && ok "all traffic goes through DoT" || bad "some queries bypass DoT"

echo "== BLOCKLISTS =="
# Status alone only describes the LAST attempt. The age of the last SUCCESSFUL
# update matters more: that is exactly the number nobody was looking at while
# the CERT Polska list sat frozen for 53 days behind a seemingly healthy panel.
podman exec pihole pihole-FTL sqlite3 /etc/pihole/gravity.db \
  "select status||'|'||cast((strftime('%s','now')-date_updated)/86400 as int)||'|'||address from adlist where enabled=1;" 2>/dev/null |
while IFS='|' read -r st days addr; do
  DESC="$addr  (last successful update: $days days ago)"
  if [ "$st" != "1" ] && [ "$st" != "2" ]; then bad "$DESC  status=$st - DOWNLOAD FAILED"
  elif [ "$days" -gt 9 ]; then bad "$DESC - list is going stale despite status=$st"
  else ok "$DESC"; fi
done

echo "== LOGS: are they growing, are they mixed up =="
J=$(sudo du -sm /var/log/journal 2>/dev/null | cut -f1)
echo "  journal: ${J} MB / 20480 MB"
PL=$(podman exec pihole sh -c "stat -c %s /var/log/pihole/pihole.log" 2>/dev/null)
echo "  pihole.log: $(( PL / 1024 )) KB (NOTE: flushed daily at 00:00 by pihole flush - this is NOT a full day's worth)"
SA=$(ls /var/log/sysstat/ 2>/dev/null | wc -l); echo "  sysstat files: $SA"
df -h / | awk "NR==2{print \"  disk: \" \$4 \" free (\" \$5 \" used)\"}"

echo "== ERRORS IN LOGS (last 24h) =="
# sigfail.verteiltesysteme.net is queried by this very script above, to check
# that DNSSEC rejects a bad signature. Its SERVFAIL is EXPECTED - without this
# exclusion the error counter grew by one on every run of the health check.
U=$(journalctl --user -u unbound.service --since "-1 day" 2>/dev/null | grep -i "servfail\|error" | grep -vc "sigfail.verteiltesysteme.net" || true)
echo "  unbound servfail/error: $U"
# "grep -c" with zero matches PRINTS 0 and exits with code 1. The previous
# "|| echo 0" then appended a SECOND zero, so $F became two lines and the
# report showed a dangling 0 on its own line. "|| true" inside the container
# handles the exit code without adding a value.
F=$(podman exec pihole sh -c "grep -ciE 'warn|error' /var/log/pihole/FTL.log || true" 2>/dev/null)
F=${F:-0}   # in case "podman exec" itself failed
echo "  FTL warn/error: $F"
# "Prefailure Attribute" is the name of a SMART attribute class, not a failure -
# smartd logs it on EVERY change of disk temperature. Without this exclusion the
# counter reported 8 warnings for a disk with PASSED health at 32 C.
S=$(sudo journalctl -t smartd --since "-1 day" 2>/dev/null | grep -i "fail\|error\|warning" | grep -vc "Prefailure Attribute" || true)
echo "  smartd warnings: $S"
sudo journalctl -u unattended-upgrades --since "-1 day" --no-pager 2>/dev/null | tail -2

echo "== HARDWARE =="
sudo /usr/sbin/smartctl -H /dev/sda 2>/dev/null | grep -i "overall-health" | sed "s/^/  /"
vcgencmd measure_temp 2>/dev/null | sed "s/^/  /"
vcgencmd get_throttled 2>/dev/null | sed "s/^/  /"
