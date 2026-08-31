import os
import time
import json
import urllib.request
import urllib.error
from datetime import datetime
from zoneinfo import ZoneInfo

from influxdb_client import InfluxDBClient, Point, WritePrecision
from influxdb_client.client.write_api import SYNCHRONOUS

INFLUXDB_URL = os.getenv("INFLUXDB_URL", "http://influxdb:8086")
INFLUXDB_TOKEN = os.getenv("INFLUXDB_TOKEN", "")
INFLUXDB_ORG = os.getenv("INFLUXDB_ORG", "home")
INFLUXDB_BUCKET = os.getenv("INFLUXDB_BUCKET", "air")

STATION_ID = int(os.getenv("GIOS_STATION_ID", ""))  # set in ~/.config/site.conf
LOCATION = os.getenv("LOCATION", "city")
INTERVAL = int(os.getenv("INTERVAL_SECONDS", "1800"))

API = "https://api.gios.gov.pl/pjp-api/v1/rest"
TZ = ZoneInfo("Europe/Warsaw")

# NOTE: the Polish strings below ("Wartość", "Wskaźnik - kod", "Data", ...) are
# field names returned by the GIOS API. They are external data, not our text -
# translating them would break the parsing.


def _list_from(payload):
    """GIOS wraps results in a key whose name differs per endpoint."""
    for value in payload.values():
        if isinstance(value, list):
            return value
    return []


def api_get(path):
    # Without an Accept header: GIOS answers 406 to "application/json".
    with urllib.request.urlopen(f"{API}/{path}", timeout=30) as resp:
        return json.load(resp)


def find_sensors():
    """Maps PM2.5/PM10 to sensor ids, skipping manual sampling points.

    A station can expose two PM10 sampling points: an automatic one (hourly
    data) and a manual one, which only reports results after 4-8 weeks and
    returns HTTP 400 in the meantime. We detect it with a probe read instead of
    hard-coding the id.
    """
    sensors = {}
    for s in _list_from(api_get(f"station/sensors/{STATION_ID}")):
        code = s.get("Wskaznik - kod") or s.get("Wskaźnik - kod")
        sid = s.get("Identyfikator stanowiska")
        if code not in ("PM2.5", "PM10") or sid is None or code in sensors:
            continue
        try:
            api_get(f"data/getData/{sid}?size=1")
        except urllib.error.HTTPError as e:
            print(f"  sensor {sid} ({code}) skipped: HTTP {e.code} (probably a manual one)")
            continue
        sensors[code] = sid
        print(f"  {code} -> sensor {sid}")
    return sensors


def fetch_measurements(sensor_id):
    """Returns [(timezone-aware datetime, value)] - the API gives about 3 days back."""
    out = []
    # size=500: without it the API returns only the first page (20 records)
    for row in _list_from(api_get(f"data/getData/{sensor_id}?size=500")):
        value = row.get("Wartosc", row.get("Wartość"))
        stamp = row.get("Data")
        if value is None or not stamp:
            continue  # GIOS returns null for hours with no validated measurement
        naive = datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S")
        out.append((naive.replace(tzinfo=TZ), float(value)))
    return out


def main():
    print(f"GIOS station {STATION_ID}, writing as location={LOCATION}")
    client = InfluxDBClient(url=INFLUXDB_URL, token=INFLUXDB_TOKEN, org=INFLUXDB_ORG)
    write_api = client.write_api(write_options=SYNCHRONOUS)

    sensors = {}
    while True:
        try:
            if not sensors:
                print("Looking up sampling points...")
                sensors = find_sensors()
                if not sensors:
                    raise RuntimeError("no PM sampling point found")

            points = []
            for code, field in (("PM2.5", "pm25"), ("PM10", "pm10")):
                sid = sensors.get(code)
                if sid is None:
                    continue
                measurements = fetch_measurements(sid)
                latest = measurements[0][1] if measurements else None
                print(f"{code}: {len(measurements)} measurements, latest = {latest}")
                for ts, value in measurements:
                    # The timestamp comes from the measurement, not from the
                    # moment we fetched it. That way a re-write overwrites the
                    # same point instead of adding duplicates, and gaps heal
                    # themselves.
                    points.append(
                        Point("air_quality")
                        .tag("sensor", "GIOS")
                        .tag("location", LOCATION)
                        .tag("station", str(STATION_ID))
                        .field(field, value)
                        .time(ts, WritePrecision.S)
                    )

            if points:
                write_api.write(bucket=INFLUXDB_BUCKET, record=points)
                print(f"Wrote {len(points)} points to InfluxDB.")
            else:
                print("Nothing to write in this cycle.")
        except Exception as e:
            print(f"Error in the main loop: {e}")
            sensors = {}  # force re-detection of the sampling points
            time.sleep(60)
            continue

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
