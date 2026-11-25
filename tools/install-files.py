#!/usr/bin/env python3
"""Copy declared source files to HOME without touching runtime databases/secrets."""
import datetime
import pathlib
import shutil
import sys

PATHS = ['.config/containers/systemd', '.config/systemd/user', '.config/alerts.conf', '.githooks', 'alerts', 'grafana', 'examples', 'city-app', 'sensor-app', 'telegraf', 'unbound', 'pihole/load-rules.sh', 'host', 'tools', 'macbook', 'install.sh', 'healthcheck.sh', 'backup.sh', 'notify.sh', 'rebuild-images.sh', 'nucleo-bridge.py', 'README.md', 'RECOVERY.md']

def install_files(source, home):
    source, home = pathlib.Path(source).resolve(), pathlib.Path(home).resolve()
    if source == home:
        return
    stamp = datetime.datetime.now().strftime('%Y%m%d%H%M%S%f')
    for name in PATHS:
        src = source / name
        if not src.exists():
            raise FileNotFoundError(f'Missing source: {src}')
        files = [src] if src.is_file() or src.is_symlink() else sorted(p for p in src.rglob('*') if p.is_file() or p.is_symlink())
        for p in files:
            if '__pycache__' in p.parts or p.suffix == '.pyc' or '.backup-' in p.name: continue
            if p.relative_to(source).parts[:2] in [('alerts', 'state'), ('alerts', 'queue')]: continue
            if p.relative_to(source).as_posix() == 'alerts/maintenance': continue
            # Rendered, site-specific dashboards are regenerated at destination.
            if p.name == 'air-quality.json': continue
            dst = home / p.relative_to(source)
            dst.parent.mkdir(parents=True, exist_ok=True)
            if dst.is_symlink() and p.is_symlink() and dst.readlink() == p.readlink(): continue
            if dst.is_file() and not dst.is_symlink() and not p.is_symlink() and dst.read_bytes() == p.read_bytes(): continue
            if dst.exists() or dst.is_symlink():
                dst.rename(dst.with_name(dst.name + '.backup-' + stamp))
            if p.is_symlink(): dst.symlink_to(p.readlink())
            else: shutil.copy2(p, dst)

if __name__ == '__main__':
    install_files(sys.argv[1], sys.argv[2])
