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
| `.config/systemd/user/` | alert timers, `alert@.service`, `OnFailure=` drop-ins |
| `alerts/` | the alerting engine: `check.sh`, `heartbeat.sh`, `unit-failed.sh`, `acl_check.py`, `image-check.sh` |
| `notify.sh` | ntfy delivery with an on-disk queue |
| `healthcheck.sh` | read-only state check |
| `backup.sh` | backup |
| `rebuild-images.sh` | rebuild the local application images |
| `install.sh` | bootstrap on a clean system |
| `grafana/` | dashboard template and provisioning |
| `examples/` | templates: the secret files and `site.conf` |

## What this repository does NOT contain

That matters more than the list above.

- **secrets** — tokens, passwords, ntfy topics and the Healthchecks UUID live in
  `~/.config/secrets/*.env` (mode 600), never in git
- **measurement data** — the `influxdb-data` and `grafana-data` volumes; you
  restore those from a backup, not from here
- **the Pi-hole query database** (`pihole-FTL.db`) — it rebuilds itself, the
  history is lost
- **`pihole.toml`** — it holds the password hash; the settings are described below

## Making it yours

Everything tied to one house lives in a single untracked file. `install.sh`
creates it from `examples/site.conf.example`; nothing else needs editing.

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

## Restoring from scratch

### 1. Packages

```bash
sudo apt update && sudo apt install -y arp-scan bind9-dnsutils curl ethtool jq \
  mtr-tiny nftables openssl podman python3 rsync smartmontools sqlite3 sysstat \
  tcpdump tree unattended-upgrades
```

### 2. Linger — without it nothing comes up

```bash
loginctl enable-linger $USER
```

User services without linger die on logout and **do not start after a reboot**.
The whole stack would be dead and nothing would say so.

### 3. Files from the repository

```bash
git clone <repo> ~/malinka && cd ~/malinka
cp -a .config alerts grafana examples *.sh *.md ~/
```

### 4. Secrets

```bash
./install.sh
```

That creates the directories, copies the templates from `examples/secrets/` into
`~/.config/secrets/` without overwriting anything, enables linger and starts the
timers. Then fill in each file. The InfluxDB tokens only exist after step 6.

### 5. Volumes from a backup

```bash
tar xzf malinka-*/app-and-quadlets.tar.gz -C ~
podman volume create influxdb-data && podman volume import influxdb-data malinka-*/influxdb-data.tar
podman volume create grafana-data  && podman volume import grafana-data  malinka-*/grafana-data.tar
tar xzf malinka-*/pihole-conf.tar.gz -C ~
sudo tar xzf malinka-*/etc.tar.gz -C /
```

### 5b. System-level hardening

`etc.tar.gz` carries the pieces that live outside `$HOME` and would otherwise be
lost on a restore:

| file | what it does |
|---|---|
| `/etc/udev/rules.d/60-jms578-trim.rules` | `provisioning_mode=unmap` and `rotational=0` for the USB bridge |
| `/etc/systemd/system/ssd-trim-limit.service` | limits UNMAP size **after** udev, when the write is finally accepted |
| `/usr/local/sbin/ssd-trim-limit.sh` | performs the write and verifies it, loudly |
| `/etc/systemd/system.conf.d/watchdog.conf` | `RuntimeWatchdogSec=15s` |
| `/etc/nsswitch.conf` | `winbind` removed from `passwd`/`group` |
| `/etc/cloud/cloud-init.disabled` | keeps cloud-init from starting |

After restoring them:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ssd-trim-limit.service
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Verify that TRIM actually works — `fstrim` reporting success is not enough:

```bash
cat /sys/class/scsi_disk/*/provisioning_mode    # must be: unmap
cat /sys/block/sda/queue/discard_max_bytes      # must be: 8388608
sudo fstrim -v / && sudo journalctl -k --since -2min | grep -c "critical target error"
```

The last number must be 0. On this hardware `fstrim` reports success while the
kernel rejects every DISCARD command, so the kernel log is the only honest check.

### 6. InfluxDB from scratch (only if you are not restoring the volume)

Organisation and bucket are whatever you set in `~/.config/site.conf`
(`INFLUXDB_ORG`, `INFLUXDB_BUCKET`). Then three narrowly scoped tokens:

| token | permissions | for |
|---|---|---|
| apps | read+write on that bucket | city-air, sds011 |
| read | read on buckets | Grafana, `check.sh` |
| admin | full | kept by hand, no service uses it |

One token for everything was the previous version of this system. A leak then
meant losing the whole database, not just the ability to append a measurement.

### 7. Local application images

`city-air` and `sds011` do not use `python:3.11-slim` directly — they have their
own images with **dependencies baked in**, so they can start with no network:

```bash
podman build -t localhost/city-air:latest ~/city-app
podman build -t localhost/sds011:latest  ~/sensor-app
```

Without this step the quadlets point at images that do not exist and the
services will not start.

Application code is **not** in the image — it is bind-mounted from `~/city-app`
and `~/sensor-app`, so a fix in `main.py` needs no rebuild. A rebuild is needed
after changing `requirements.txt`, or to pick up base-image patches:
`~/rebuild-images.sh`.

### 8. Start-up

```bash
systemctl --user daemon-reload
systemctl --user enable --now alerts.timer heartbeat.timer daily-check.timer
```

Containers enable themselves — the quadlets carry `WantedBy=default.target`.

```bash
crontab -e    # * * * * * $HOME/sample-site/update_temp.sh
~/pihole/load-rules.sh   # blocklists and custom rules, once Pi-hole is up
```

### 9. Pre-commit hook

```bash
git config core.hooksPath .githooks
```

Without it nothing stops you from committing a secret.

### 10. Verification

```bash
./healthcheck.sh           # everything green?
~/alerts/check.sh -v       # do the alert rules pass?
~/notify.sh test           # does a notification reach the phone?
~/alerts/heartbeat.sh      # does the heartbeat reach Healthchecks?
```

## Alerting — six layers

| layer | what it watches | where |
|---|---|---|
| 0 | the ntfy channel with an on-disk queue | `notify.sh` |
| 1 | whether the host is alive at all (Healthchecks) | `alerts/heartbeat.sh` |
| 2 | data freshness, DNS, blocking, clock, apt | `alerts/check.sh` |
| 3 | a unit in the `failed` state | `OnFailure=` drop-ins |
| 4 | the daily check at 07:00 | `alerts/daily-check.sh` |
| 5 | disk, temperature, SMART, restart loops, IPv6 prefix, image age | `alerts/check.sh` |

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

## Container images

Every registry image here is pinned to a moving tag (`:latest`, `:2`) and
**nothing pulls it on its own**. `unattended-upgrades` patches Debian and does
not look inside a container, so without a deliberate act the containers keep
running whatever was current on the day they were pulled. On 2026-09-03 that
was an eight-month-old nginx.

`podman-auto-update.timer` is the obvious answer and it is **masked on
purpose**. It pulls *and restarts*, daily, with up to 15 minutes of random
delay — an unannounced restart of Pi-hole is an unannounced DNS outage for the
whole house, at an hour nobody chose. The mask is committed
(`.config/systemd/user/podman-auto-update.timer -> /dev/null`) so a restore
cannot quietly reinstate it.

What runs instead is `alerts/image-check.sh` on `image-check.timer`, Mondays at
08:00: it asks the registry for the digest behind each tag, compares it with
the local one, and **sends a notification if they differ**. It pulls nothing
and restarts nothing.

Updating is a manual, chosen act:

```bash
~/alerts/image-check.sh --verbose   # what is actually stale, and why
podman auto-update                  # pulls AND restarts everything labelled
systemctl --user restart pihole     # or one at a time, if you prefer
```

Two things worth knowing before trusting the output:

- Every registry-backed quadlet carries `AutoUpdate=registry`. The label is
  what makes `podman auto-update` work; on its own it does nothing, because
  nothing scheduled ever calls it.
- `podman auto-update --dry-run` reads that label from the **running**
  container, and a container only receives it when it is next created. These
  run with `Restart=always` and can go months without being recreated, so the
  native dry-run stays silent about a genuinely stale image. That is why
  `image-check.sh` reads the quadlet files instead — it is correct from the
  first run, before anything has been restarted.

Locally built images (`localhost/city-air`, `localhost/sds011`) are a separate
rule in `alerts/check.sh`, by build date, pointing at `~/rebuild-images.sh`.
Between the two, every image is covered exactly once.

## Backups

Run **from the MacBook**, not from the Pi — Google Drive is mounted there and
the Pi has no access to it.

```bash
~/malinka-backups/backup-all.sh
```

Six steps: archive on the Pi → download → compare checksums → encrypt and
**attempt a decrypt** → upload to Drive → clean up.

Only the **newest** copy is kept, in three places:

| where | form |
|---|---|
| Pi `~/backups/` | plaintext |
| MacBook `~/malinka-backups/` | plaintext + encrypted |
| Google Drive `malinka-backup/` | **encrypted only** |

Older copies are deleted **only after** every check has passed. If any of them
fails, the script exits with an error and deletes nothing.

The archive passphrase lives in `~/malinka-backups/.archive-passphrase`
(mode 600) and **must also be in a password manager** — without it the Drive
copy is useless in exactly the scenario it exists for. The script never
generates a new passphrase on its own: doing so would silently make older
archives undecryptable, and you would find out only while restoring.

A deliberate trade-off: one generation does not protect you from a mistake made
a few days ago, once all three copies are already downstream of it.

`~/backup.sh` on the Pi still works on its own, but it only produces a local
archive — nothing leaves the machine.

## Things that are easy to forget

- **Once a month, `~/notify.sh test`.** An alert that has never fired is
  indistinguishable from a broken one.
- **The ISP's IPv6 prefix is leased.** After a renumbering the `webserver.acl`
  entry stops matching and phones lose access to the panel.
  `alerts/acl_check.py` watches for that and prints a ready-to-paste fix.
- **A copy on the same disk protects against your own mistake, not an SSD
  failure.** Take it elsewhere, encrypted — it holds a full set of credentials.
- **After rotating secrets, take a fresh backup.** The old one restores
  credentials that no longer work.
