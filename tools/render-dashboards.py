#!/usr/bin/env python3
import json
import pathlib
import sys


def site_values(path):
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            key, value = line.split('=', 1)
            values[key] = value
    return values


def render(home):
    home = pathlib.Path(home)
    site = site_values(home / '.config/site.conf')
    mapping = {'__BUCKET__': site['INFLUXDB_BUCKET'], '__LOC_HOME__': site['SENSOR_LOCATION'], '__LOC_CITY__': site['LOCATION']}
    template = home / 'grafana/dashboards/air-quality.json.in'
    # JSON-escape values while they are substituted inside query strings.
    text = template.read_text()
    for key, value in mapping.items(): text = text.replace(key, json.dumps(value)[1:-1])
    data = json.loads(text)
    template.with_suffix('').write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')

if __name__ == '__main__': render(sys.argv[1])
