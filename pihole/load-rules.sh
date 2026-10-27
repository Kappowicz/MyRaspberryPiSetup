#!/bin/bash
# Loads the vetted blocklists, regex rules and allowlists into Pi-hole.
# Useful on a fresh install or after wiping the gravity.db database.
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

echo "== 1/3 checking the Pi-hole container =="
podman ps --format '{{.Names}}' | grep -q '^pihole$' || {
  echo "Error: the pihole container is not running. Start it with: systemctl --user start pihole" >&2
  exit 1
}

echo "== 2/3 adding blocklists (adlists) =="
podman exec pihole pihole-FTL sqlite3 /etc/pihole/gravity.db "
INSERT OR IGNORE INTO adlist (address, enabled, comment) VALUES
  ('https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts', 1, 'StevenBlack general base list'),
  ('https://big.oisd.nl/', 1, 'OISD Big - ads and trackers'),
  ('https://hole.cert.pl/domains/v2/domains_hosts.txt', 1, 'CERT Polska warning list'),
  ('https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-hosts.txt', 1, 'URLhaus malware'),
  ('https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.apple.txt', 1, 'HaGeZi - Apple native trackers and telemetry'),
  ('https://raw.githubusercontent.com/PolishFiltersTeam/KADhosts/master/KADhosts.txt', 1, 'KADhosts - Polish ads and scams');
"

echo "== 3/3 adding custom rules (allowlist / regex / denylist) =="
# type: 0=exact allow, 1=exact deny, 2=regex allow, 3=regex deny
podman exec pihole pihole-FTL sqlite3 /etc/pihole/gravity.db "
-- Allowlist (exceptions)
INSERT OR IGNORE INTO domainlist (domain, type, enabled, comment) VALUES
  ('pagead2.googlesyndication.com', 0, 1, 'tvp vod exception'),
  ('global.appnext.com', 0, 1, 'tvp vod exception');

-- Regex denylist (ads, telemetry, trackers)
INSERT OR IGNORE INTO domainlist (domain, type, enabled, comment) VALUES
  ('(\\.|^)jbzd\\.com\\.pl\$', 3, 1, 'block jbzd'),
  ('(\\.|^)appsflyersdk\\.com\$', 3, 1, 'appsflyer mobile trackers'),
  ('(\\.|^)crashlytics\\.com\$', 3, 1, 'crashlytics telemetry'),
  ('(\\.|^)gemius\\.pl\$', 3, 1, 'gemius tracking (PL)'),
  ('(\\.|^)gemius\\.com\$', 3, 1, 'gemius tracking (global)'),
  ('(\\.|^)samsungads\\.com\$', 3, 1, 'ads in the Samsung Smart TV menu'),
  ('(\\.|^)events\\.data\\.microsoft\\.com\$', 3, 1, 'Windows/Office/Teams telemetry'),
  ('(\\.|^)pushpushgo\\.com\$', 3, 1, 'webpush pop-up notifications'),
  ('(\\.|^)clarity\\.ms\$', 3, 1, 'Microsoft Clarity session recording'),
  ('(\\.|^)metrika\\.yandex\\.ru\$', 3, 1, 'Yandex Metrika tracking'),
  ('(\\.|^)byteoversea\\.com\$', 3, 1, 'TikTok / ByteDance telemetry');

-- Exact denylist
INSERT OR IGNORE INTO domainlist (domain, type, enabled, comment) VALUES
  ('dls.di.atlas.samsung.com', 1, 1, 'Samsung TV app telemetry'),
  ('telemetry.paradox-interactive.com', 1, 1, 'Paradox game telemetry');
"

# The ISP search suffix is site-specific (it names the ISP and the region), so
# it lives only in the untracked site.conf - never in this file.
[ -f "$HOME/.config/site.conf" ] && . "$HOME/.config/site.conf"
if [ -n "${DHCP_SEARCH_SUFFIX:-}" ]; then
  SUFFIX_RE="(\\.|^)$(printf '%s' "$DHCP_SEARCH_SUFFIX" | sed 's/\./\\./g')\$"
  podman exec pihole pihole-FTL sqlite3 /etc/pihole/gravity.db "
INSERT OR IGNORE INTO domainlist (domain, type, enabled, comment) VALUES
  ('$SUFFIX_RE', 2, 1, 'workaround for the ISP DHCP search suffix');
"
fi

echo "== rebuilding the gravity database =="
podman exec pihole pihole -g

echo "Done. All lists and rules have been loaded."
