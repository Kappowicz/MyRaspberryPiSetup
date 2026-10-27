# Malinka — Pi-hole, unbound, dust sensor, charts, alerts

Configuration for a Raspberry Pi acting as an ad-blocking DNS server
(Pi-hole + unbound over DoT), collecting air quality from an SDS011 sensor and
from a public GIOS station, with charts in Grafana and alerts pushed to a
phone.

Containers run **rootless** via podman + quadlets, as user services.

## What is in this repository

| path | contents |
|---|---|
| `.config/containers/systemd/` | quadlets — container definitions |
| `.config/systemd/user/` | alert timers, `boot-notify.service`, `alert@.service`, `OnFailure=` drop-ins |
| `alerts/` | the alerting engine: `check.sh`, `heartbeat.sh`, `unit-failed.sh`, `acl_check.py`, `image-check.sh`, `boot-notify.sh` |
| `notify.sh` | ntfy delivery with an on-disk queue |
| `healthcheck.sh` | read-only state check |
| `backup.sh` | backup |
| `rebuild-images.sh` | rebuild the local application images |
| `install.sh` | bootstrap on a clean system |
| `host/`, `tools/` | reviewed host profile and recovery helpers |
| `pihole/load-rules.sh` | blocklists and custom exceptions |
| `macbook/` | portable download/encryption script and config template |
| `grafana/` | dashboard templates and provisioning |
| `telegraf/` | Telegraf host and hardware metrics collector configuration |
| `examples/` | templates: the secret files and `site.conf` |

## What this repository does NOT contain

That matters more than the list above.

- **secrets** — tokens, passwords, ntfy topics and the Healthchecks UUID live in
  `~/.config/secrets/*.env` (mode 600), never in git
- **measurement data** — the `influxdb-data` and `grafana-data` volumes; you
  restore those from a backup, not from here
- **the Pi-hole query database** (`pihole-FTL.db`) — it rebuilds itself, the
  history is lost
- **`pihole.toml`** — it holds the password hash; private customization is recovered from backup

## Making it yours

Everything tied to one house lives in a single untracked file. `install.sh`
creates it from `examples/site.conf.example`; secrets are configured separately.

```bash
cp examples/site.conf.example ~/.config/site.conf   # install.sh does this too
$EDITOR ~/.config/site.conf
```

| key | what it is |
|---|---|
| `INFLUXDB_ORG`, `INFLUXDB_BUCKET` | names you pick when creating the database |
| `GIOS_STATION_ID` | the public air quality station nearest to you. Find it at <https://powietrze.gios.gov.pl/pjp/current> — the id is in the URL of the station |
| `LOCATION` | tag written for that station's data (default `city`) |
| `SENSOR_LOCATION` | tag written for your own SDS011 (default `home`) |
| `DHCP_SEARCH_SUFFIX` | the search suffix your ISP router hands out, if any. Leave empty if none |

The quadlets read this file directly as an `EnvironmentFile=`, `alerts.conf`
sources it, and the Grafana dashboard is **rendered** from
`grafana/dashboards/air-quality.json.in` with the location tags substituted, so
the charts follow whatever you called your sensor. Re-run `install.sh` after
changing the labels.

Outside this file, the only site-specific thing left is the LAN address in the
`PublishPort=` lines of the quadlets. Those bind on every interface as written,
so set them to your LAN address, or scope the ports with an `nftables` ruleset,
before exposing the machine to a network you do not control.

## Recovery

Follow [RECOVERY.md](RECOVERY.md) for fresh setup and data restoration.
Run `bash install.sh --packages --host` to prepare the host and all public files,
then restore secrets/data and run `bash ~/install.sh --start`. A plain
`bash install.sh` prepares files only. Existing secrets are preserved.

## Alerting — six layers

| layer | what it watches | where |
|---|---|---|
| 0 | the ntfy channel with an on-disk queue | `notify.sh` |
| 1 | whether the host is alive at all (Healthchecks) | `alerts/heartbeat.sh` |
| 2 | data freshness, DNS, blocking, clock, apt, reboot-required | `alerts/check.sh` |
| 3 | a unit in the `failed` state | `OnFailure=` drop-ins |
| 4 | the daily check at 07:00 | `alerts/daily-check.sh` |
| 5 | hardware (disk, mem, temp, throttling, SMART), restart loops, IPv6 prefix, image & backup age | `alerts/check.sh` |

Layer 1 lives **outside** on purpose: an alarm running on the host cannot tell
you the host is dead. The dead do not shout.

The queue in `~/alerts/queue` holds notifications through a severed link and
delivers them once it is back, annotated with the delay. When the queue has been
stuck for more than 30 minutes, `heartbeat.sh` reports that to Healthchecks —
over an independent path, because a broken notification channel cannot announce
itself.

Planned maintenance does not page you: `backup.sh` raises
`~/alerts/maintenance` while it deliberately stops services. The flag expires
after 15 minutes, so a backup that dies halfway cannot silence alerting for good.

## Images and backups

Registry images and Python packages are pinned to the reviewed deployment.
`python3 ~/tools/update-images.py --pull` updates digest declarations for review;
apply restarts deliberately. Registry checks continue to report newer tags.

`backup.sh` creates consistent database snapshots and archives site.conf, secrets,
SSH configuration, applications and host settings. Only verified backups get a
SUCCESS marker and final directory name. Failed backups remain hidden partials.
See [Mac backup setup](macbook/README.md) for downloading and encryption.

Full restoration depends on the encrypted backup and its separately stored
passphrase. Keep private runtime files outside Git and test recovery periodically.
