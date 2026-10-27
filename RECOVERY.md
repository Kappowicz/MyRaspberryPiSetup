# Recovering the Raspberry Pi

The target is Raspberry Pi 5, Debian 13 arm64, rootless Podman with crun and
cgroup v2, with the Raspberry Pi package repository (raspi-utils-core). Keep an encrypted data backup and its passphrase outside the Pi.
Git contains public configuration; tokens, site.conf, databases and SSH keys
are deliberately private. A Git checkout alone cannot restore historical data.

## Restore from backup

1. Install the OS and create the user. Prefer the same user/UID and subordinate
   UID/GID ranges recorded in user-identity.txt and etc.tar.gz. Enable SSH, plug
   in the SSD and SDS011, and verify the disk/device identities before proceeding.
2. Decrypt outside any cloud-synced directory:

   ```sh
   mkdir -m 700 ~/restore
   openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
     -in malinka-DATE-TIME.tar.gz.enc | tar xzf - -C ~/restore
   cd ~/restore/malinka-DATE-TIME
   sha256sum -c SHA256SUMS
   ```

   Require SUCCESS and all checksums to pass for new backups. Older archives
   lack these markers and site.conf; inspect them manually and recover the site
   values separately. The passphrase comes from your password manager.
3. Extract app-and-quadlets.tar.gz to the user's home, preserving permissions.
   It includes site.conf, secrets, applications and .ssh. Review restored SSH
   keys and authorized_keys. Keep services stopped while restoring databases.
4. Run `bash ~/install.sh --packages --host` to prepare packages, groups, port
   53, watchdog, SSD trim, journald, SMART, sysstat and security-only updates. Log out and back in to activate group membership.
   Review etc.tar.gz separately for journald, SMART, sysstat, unattended upgrades
   and hardware choices. Do not blindly replace boot/config.txt, subuid/subgid,
   nsswitch.conf or disk settings on different hardware. `host/setup-host.sh
   user --headless` additionally disables Wi-Fi/Bluetooth/audio; use only over
   wired Ethernet. Reboot deliberately for boot/watchdog changes.
5. Restore named volumes while containers are stopped:

   ```sh
   podman volume create influxdb-data
   podman volume import influxdb-data ~/restore/malinka-DATE-TIME/influxdb-data.tar
   podman volume create grafana-data
   podman volume import grafana-data ~/restore/malinka-DATE-TIME/grafana-data.tar
   ```

   If a volume exists, check whether it contains data before importing. Review
   ownership when changing host UID or subordinate ID ranges.
6. Extract pihole-conf.tar.gz with sudo into the user's home. New backups store
   gravity.db separately using SQLite's consistent backup API:

   ```sh
   sudo cp ~/restore/malinka-DATE-TIME/gravity.db ~/pihole/etc-pihole/gravity.db
   sudo chown --reference=~/pihole/etc-pihole/pihole.toml ~/pihole/etc-pihole/gravity.db
   sudo chmod 660 ~/pihole/etc-pihole/gravity.db
   ```

   Check the actual Pi-hole file ownership before applying the chown command.
   Private pihole.toml restores UI credentials and customization. Query history
   is intentionally excluded. On a fresh database run pihole/load-rules.sh only
   after Pi-hole starts; it loads lists and custom domain exceptions.
7. Set the read token also as INFLUXDB_TOKEN in secrets/grafana.env. Ensure that
   influx-read.env's token can read both air and system_metrics buckets. Align
   org/buckets in site.conf and influx-telegraf.env. Keep these files mode 600.
   Run `python3 ~/tools/validate-config.py "$HOME"`, then `bash ~/install.sh --start`.
   The installer checks prerequisites before starting services and alert timers.
8. Run `~/healthcheck.sh`, confirm DNS from another LAN device, check both
   Grafana dashboards, sensor readings, timers and `loginctl show-user user -p
   Linger`. Healthcheck exits nonzero when any checked health condition fails.
   Review restored user cron with `crontab-user.txt` before installing it; the
   optional updater jobs may restart services. Do not run duplicate schedulers.

## Fresh install without data

Clone this repository to any directory and run `bash install.sh --packages
--host`. It copies all declared public files into HOME and creates missing
private templates, without replacing existing secrets. Fill in site.conf and
secret files. Images and Python dependencies are pinned to the reviewed versions.

For a new InfluxDB database, pull the pinned InfluxDB image from its quadlet,
create influxdb-data and the sensor-net network (`podman network create
--dns=169.254.1.1 systemd-sensor-net`), then `systemctl --user daemon-reload` and `systemctl --user
start influxdb`. Use its web onboarding on port 8086 to create the organization
and air bucket, then add system_metrics. Generate separate write/read tokens
with permissions for the corresponding buckets and fill in the secret files.
The restored-volume path does not require onboarding. Configure Pi-hole's UI
password on a fresh install. Finish with `bash ~/install.sh --start` and load
Pi-hole rules. The SDS011 path is `/dev/serial/by-id/usb-1a86_USB_Serial-if00-port0`;
update the quadlet if your USB adapter has a different stable identity.

## Maintenance and backup

`backup.sh` briefly stops Grafana/InfluxDB and preserves the original active
state of dependent services. Pi-hole stays online. A lock prevents overlapping
runs. Failed directories remain hidden `.partial` for investigation; only a
verified backup is atomically published with SUCCESS and SHA256SUMS. Backups
include private configuration and SSH keys, so keep directories mode 700.

The tracked macbook/backup-all.sh downloads, verifies, encrypts and checks a
round trip before copying to the mounted Google Drive directory. Its private
backup.conf and existing passphrase are not in Git. The existing one-generation
retention policy cannot undo older mistakes. A verified local Drive copy does
not confirm that cloud synchronization has finished.

Run `python3 ~/tools/update-images.py --pull` to intentionally select current
registry tag digests. Review the resulting diff, rebuild the local Python
images if the base changed, then restart services during a maintenance window.
Image alerts still report newer registry tags; automatic registry updates are
replaced by reviewed digest changes. Never run rebuild-images.sh during normal
DNS-dependent activity without planning its restarts.
