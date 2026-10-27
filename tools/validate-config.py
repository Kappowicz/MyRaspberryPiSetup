#!/usr/bin/env python3
"""Validate local configuration without logging credentials or sending notifications."""
import pathlib
import sys


def env(path):
    result = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'): continue
        key, value = line.split('=', 1)
        result[key.strip()] = value.strip()
    return result


def validate(home):
    home = pathlib.Path(home)
    required = {'site.conf': ['INFLUXDB_ORG', 'INFLUXDB_BUCKET', 'GIOS_STATION_ID', 'LOCATION', 'SENSOR_LOCATION'],
                'secrets/influx-apps.env': ['INFLUXDB_TOKEN'], 'secrets/influx-telegraf.env': ['INFLUXDB_TOKEN', 'INFLUXDB_ORG', 'INFLUXDB_BUCKET'],
                'secrets/influx-read.env': ['INFLUXDB_TOKEN'], 'secrets/grafana.env': ['GF_SECURITY_ADMIN_PASSWORD', 'INFLUXDB_TOKEN'],
                'secrets/notify.env': ['NTFY_ALARM', 'NTFY_INFO'], 'secrets/heartbeat.env': ['HC_URL']}
    errors = []
    for name, keys in required.items():
        p = home / '.config' / name
        if not p.is_file(): errors.append(f'Missing {name}'); continue
        if p.stat().st_mode & 0o077: errors.append(f'{name}: expected permissions 600')
        try: data = env(p)
        except ValueError: errors.append(f'{name}: invalid KEY=value syntax'); continue
        for key in keys:
            value = data.get(key, '')
            if not value or any(marker in value for marker in ['PASTE_', 'SET_A_', 'RANDOM_STRING', 'YOUR_TOKEN']): errors.append(f'{name}: fill in {key}')
        if name == 'site.conf' and not data.get('GIOS_STATION_ID', '').isdigit(): errors.append('site.conf: GIOS_STATION_ID must be numeric')
    if errors: raise ValueError('\n'.join(errors))

if __name__ == '__main__':
    try: validate(sys.argv[1])
    except (ValueError, OSError) as e: print(e, file=sys.stderr); sys.exit(1)
