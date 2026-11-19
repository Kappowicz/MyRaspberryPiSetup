#!/usr/bin/env python3
"""Bridge between a NUCLEO-G491RE (SCD41 CO2 sensor + e-ink display) and InfluxDB + calendars.

- Reads the latest room (SDS011, SENSOR_LOCATION) and city (GIOS, LOCATION) PM2.5/PM10 from
  InfluxDB and sends them as JSON to the Nucleo every 5 minutes.
- Fetches iCal (.ics) feeds from ~/.config/secrets/calendars.conf and merges shared events from
  ~/.config/secrets/extra_events.json.
- Events from calendars whose label matches CALENDAR_GREY_LABELS (site.conf) are sent with
  grey=1, so the Nucleo renders them in halftone grey, prefixed with CALENDAR_GREY_PREFIX.
  Names stay in site.conf: this file is committed and the repository is public.
- Pushes up to 9 upcoming events to the Nucleo.
- Writes the SCD41 readings the Nucleo reports (co2/temp/humidity) to InfluxDB every 30 s.
"""
import csv
import errno
import glob
import io
import json
import os
import re
import select
import termios
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

# The by-id path carries the ST-LINK serial number; a glob instead of the full
# name means a replacement board works without editing this file.
# NUCLEO_SERIAL_DEV in site.conf overrides it if a second ST-LINK ever appears.
SERIAL_GLOB = "/dev/serial/by-id/usb-STMicroelectronics_STLINK-V3_*-if02"
TZ = ZoneInfo("Europe/Warsaw")
CALENDARS_CONF = os.path.expanduser("~/.config/secrets/calendars.conf")
EXTRA_EVENTS_JSON = os.path.expanduser("~/.config/secrets/extra_events.json")

PL_MAP = str.maketrans({
    "ą": "A", "ć": "C", "ę": "E", "ł": "L", "ń": "N", "ó": "O", "ś": "S", "ź": "Z", "ż": "Z",
    "Ą": "A", "Ć": "C", "Ę": "E", "Ł": "L", "Ń": "N", "Ó": "O", "Ś": "S", "Ź": "Z", "Ż": "Z",
})


def to_ascii_upper(s):
    s = (s or "").translate(PL_MAP).upper()
    s = re.sub(r"[^A-Z0-9 :.\-+()/!?#%]", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def load_env_file(path):
    if not os.path.exists(path):
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())


load_env_file(os.path.expanduser("~/.config/site.conf"))
load_env_file(os.path.expanduser("~/.config/secrets/influx-apps.env"))

INFLUX_URL = "http://127.0.0.1:8086"
INFLUX_ORG = os.environ.get("INFLUXDB_ORG", "home")
INFLUX_BUCKET = os.environ.get("INFLUXDB_BUCKET", "air")
INFLUX_TOKEN = os.environ.get("INFLUXDB_TOKEN", "")
ROOM_LOC = os.environ.get("SENSOR_LOCATION", "home")
CITY_LOC = os.environ.get("LOCATION", "city")
# Comma-separated, matched case-insensitively against the label in calendars.conf.
GREY_LABELS = [to_ascii_upper(x) for x in os.environ.get("CALENDAR_GREY_LABELS", "").split(",") if x.strip()]
GREY_PREFIX = to_ascii_upper(os.environ.get("CALENDAR_GREY_PREFIX", ""))

# Push air data + calendar to the Nucleo every 5 min. Indoor CO2, PM and the
# calendar change on a scale of minutes, and every push is a chance for the
# e-ink to redraw (wear, flashing); 20 s gave nothing but sensor noise.
PUSH_INTERVAL_S = 300.0
CALENDAR_FETCH_INTERVAL_S = 300.0
# SCD41 -> InfluxDB stays denser than the display: a window opened for a few
# minutes should still be visible on the Grafana CO2 chart.
INFLUX_WRITE_INTERVAL_S = 30.0


def find_serial_dev():
    explicit = os.environ.get("NUCLEO_SERIAL_DEV", "")
    if explicit:
        return explicit
    found = sorted(glob.glob(SERIAL_GLOB))
    if not found:
        raise OSError(f"no device matches {SERIAL_GLOB}")
    return found[0]


def write_all(fd, data, timeout=2.0):
    """os.write on the O_NONBLOCK port raises EAGAIN when the USB CDC buffer is
    full (seen 2026-11-18). Before this, that was treated as a dead port: the
    bridge reconnected and the reconnect forced a full e-ink refresh."""
    deadline = time.monotonic() + timeout
    while data:
        try:
            n = os.write(fd, data)
            data = data[n:]
        except BlockingIOError:
            left = deadline - time.monotonic()
            if left <= 0:
                raise OSError(errno.EAGAIN, "serial write timed out")
            select.select([], [fd], [], left)


def open_serial(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def query_influx_air():
    flux = (
        f'from(bucket: "{INFLUX_BUCKET}") '
        f'|> range(start: -24h) '
        f'|> filter(fn: (r) => r._measurement == "air_quality" and (r._field == "pm25" or r._field == "pm10")) '
        f'|> last()'
    )
    req = urllib.request.Request(
        f"{INFLUX_URL}/api/v2/query?org={INFLUX_ORG}",
        data=flux.encode("utf-8"),
        headers={
            "Authorization": f"Token {INFLUX_TOKEN}",
            "Accept": "application/csv",
            "Content-Type": "application/vnd.flux",
        },
        method="POST",
    )
    out = {"room_pm25": -1.0, "room_pm10": -1.0, "city_pm25": -1.0, "city_pm10": -1.0}
    with urllib.request.urlopen(req, timeout=10) as resp:
        text = resp.read().decode("utf-8", errors="replace")
    for row in csv.DictReader(io.StringIO(text)):
        loc = row.get("location")
        field = row.get("_field")
        try:
            val = float(row.get("_value", ""))
        except ValueError:
            continue
        if loc == ROOM_LOC and field in ("pm25", "pm10"):
            out[f"room_{field}"] = round(val, 1)
        elif loc == CITY_LOC and field in ("pm25", "pm10"):
            out[f"city_{field}"] = round(val, 1)
    return out


def parse_ics_dt(raw_key, raw_val):
    val = raw_val.strip()
    is_all_day = ("VALUE=DATE" in raw_key and "DATE-TIME" not in raw_key) or len(val) == 8
    try:
        if is_all_day:
            d = datetime.strptime(val[:8], "%Y%m%d").date()
            dt = datetime(d.year, d.month, d.day, 0, 0, tzinfo=TZ)
            return dt, True
        if val.endswith("Z"):
            dt = datetime.strptime(val[:15], "%Y%m%dT%H%M%S").replace(tzinfo=timezone.utc).astimezone(TZ)
            return dt, False
        dt = datetime.strptime(val[:15], "%Y%m%dT%H%M%S").replace(tzinfo=TZ)
        return dt, False
    except Exception:
        return None, False


def parse_ics_events(ics_text, is_grey, now_dt):
    unfolded = re.sub(r"\r?\n[ \t]", "", ics_text)
    events = []
    in_event = False
    cur = {}
    for line in unfolded.splitlines():
        if line == "BEGIN:VEVENT":
            in_event = True
            cur = {}
        elif line == "END:VEVENT" and in_event:
            in_event = False
            if cur.get("STATUS") == "CANCELLED":
                continue
            dt, all_day = cur.get("DTSTART", (None, False))
            summary = cur.get("SUMMARY", "")
            if dt is not None and summary:
                end_dt, _ = cur.get("DTEND", (None, False))
                if end_dt is None:
                    end_dt = dt + (timedelta(days=1) if all_day else timedelta(hours=1))
                if end_dt >= now_dt:
                    events.append((dt, all_day, summary, is_grey))
        elif in_event and ":" in line:
            k, v = line.split(":", 1)
            k_base = k.split(";", 1)[0].upper()
            if k_base == "DTSTART":
                cur["DTSTART"] = parse_ics_dt(k.upper(), v)
            elif k_base == "DTEND":
                cur["DTEND"] = parse_ics_dt(k.upper(), v)
            elif k_base == "SUMMARY":
                cur["SUMMARY"] = v.replace("\\,", ",").replace("\\;", ";").replace("\\n", " ")
            elif k_base == "STATUS":
                cur["STATUS"] = v.strip().upper()
    return events


def load_extra_events(now_dt):
    if not os.path.exists(EXTRA_EVENTS_JSON):
        return []
    out = []
    try:
        with open(EXTRA_EVENTS_JSON) as f:
            items = json.load(f)
        for it in items:
            dt_str = it.get("start", "")
            all_day = bool(it.get("all_day", False))
            grey = 1 if it.get("grey", False) else 0
            title = it.get("title", "")
            if all_day:
                d = datetime.strptime(dt_str[:10], "%Y-%m-%d").date()
                dt = datetime(d.year, d.month, d.day, 0, 0, tzinfo=TZ)
                end_dt = dt + timedelta(days=1)
            else:
                dt = datetime.strptime(dt_str[:16], "%Y-%m-%dT%H:%M").replace(tzinfo=TZ)
                end_dt = dt + timedelta(hours=1)
            if end_dt >= now_dt:
                out.append((dt, all_day, title, grey))
    except Exception as e:
        print(f"Extra events error: {e}", flush=True)
    return out


def fetch_upcoming_calendar_events():
    now_dt = datetime.now(TZ)
    today = now_dt.date()
    tomorrow = today + timedelta(days=1)
    all_events = []

    if os.path.exists(CALENDARS_CONF):
        with open(CALENDARS_CONF) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                is_grey = 0
                u = line
                if "=" in line and not line.lower().startswith(("http://", "https://", "webcal://")):
                    lbl, u = line.split("=", 1)
                    if any(g in to_ascii_upper(lbl) for g in GREY_LABELS):
                        is_grey = 1
                    u = u.strip()
                if u.startswith("webcal://"):
                    u = "https://" + u[len("webcal://"):]
                try:
                    req = urllib.request.Request(u, headers={"User-Agent": "NucleoCalendar/1.0"})
                    with urllib.request.urlopen(req, timeout=15) as resp:
                        body = resp.read().decode("utf-8", errors="replace")
                    if body.lstrip().startswith("["):
                        for it in json.loads(body):
                            dt_s = it.get("start", "")
                            all_d = bool(it.get("all_day", False))
                            g_fl = 1 if it.get("grey", is_grey) else 0
                            tit = it.get("title", "")
                            if not dt_s or not tit:
                                continue
                            if all_d:
                                d = datetime.strptime(dt_s[:10], "%Y-%m-%d").date()
                                dt = datetime(d.year, d.month, d.day, 0, 0, tzinfo=TZ)
                                end_dt = dt + timedelta(days=1)
                            else:
                                dt = datetime.fromisoformat(dt_s.replace("Z", "+00:00")).astimezone(TZ)
                                end_dt = dt + timedelta(hours=1)
                            if end_dt >= now_dt:
                                all_events.append((dt, all_d, tit, g_fl))
                    else:
                        all_events.extend(parse_ics_events(body, is_grey, now_dt))
                except Exception as e:
                    print(f"Calendar fetch error ({u[:32]}): {e}", flush=True)

    all_events.extend(load_extra_events(now_dt))
    all_events.sort(key=lambda x: (x[0], x[3]))

    formatted = []
    seen = set()
    for dt, all_day, summary, is_grey in all_events:
        d = dt.date()
        if d == today:
            day_s = "DZIS"
        elif d == tomorrow:
            day_s = "JUTRO"
        else:
            day_s = dt.strftime("%d.%m")
        time_s = "CALY" if all_day else dt.strftime("%H:%M")
        when_s = f"{day_s} {time_s}"[:11]
        title_s = to_ascii_upper(summary)
        if is_grey and GREY_PREFIX and not title_s.startswith(GREY_PREFIX):
            title_s = f"{GREY_PREFIX}: {title_s}"
        title_s = title_s[:34]
        key = (d.isoformat(), title_s[:18])
        if key in seen:
            continue
        seen.add(key)
        formatted.append((when_s, title_s, is_grey))
        if len(formatted) >= 9:
            break
    return formatted


def write_influx_scd41(co2, temp, hum):
    line = f"air_quality,sensor=SCD41,location={ROOM_LOC} co2={int(co2)}i,temp={float(temp):.2f},humidity={float(hum):.2f}\n"
    req = urllib.request.Request(
        f"{INFLUX_URL}/api/v2/write?org={INFLUX_ORG}&bucket={INFLUX_BUCKET}&precision=s",
        data=line.encode("utf-8"),
        headers={
            "Authorization": f"Token {INFLUX_TOKEN}",
            "Content-Type": "text/plain; charset=utf-8",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        resp.read()


def main():
    fd = None
    rx_buf = b""
    last_push = 0.0
    last_cal_fetch = 0.0
    last_influx_write = 0.0
    cached_events = []
    first_push = True
    # Logged once per (re)connect, so the journal shows the sensor is alive
    # without the ~30k lines a day that printing every reading produced.
    logged_first_reading = False

    while True:
        try:
            if fd is None:
                dev = find_serial_dev()
                fd = open_serial(dev)
                print(f"Opened {dev}", flush=True)
                first_push = True
                last_push = 0.0
                logged_first_reading = False

            now = time.time()
            if now - last_cal_fetch >= CALENDAR_FETCH_INTERVAL_S or first_push:
                cached_events = fetch_upcoming_calendar_events()
                last_cal_fetch = now

            if now - last_push >= PUSH_INTERVAL_S:
                # An InfluxDB outage (backup.sh stops it nightly) used to raise
                # out of the loop and drop the serial port, so every query
                # retry was a reconnect + forced full e-ink refresh. Now the
                # display gets -1 ("no data") and the calendar still goes out.
                try:
                    air = query_influx_air()
                except Exception as e:
                    print(f"Influx query error: {e}", flush=True)
                    air = {"room_pm25": -1.0, "room_pm10": -1.0, "city_pm25": -1.0, "city_pm10": -1.0}
                air["time"] = datetime.now(TZ).strftime("%H:%M")

                cal_hdr = json.dumps({"cal_n": len(cached_events)}, separators=(",", ":")) + "\n"
                write_all(fd, cal_hdr.encode("ascii"))
                time.sleep(0.03)
                for idx, (w_str, t_str, g_flag) in enumerate(cached_events):
                    cl = json.dumps({"c": idx, "g": g_flag, "w": w_str, "t": t_str[:26]}, separators=(",", ":")) + "\n"
                    write_all(fd, cl.encode("ascii"))
                    time.sleep(0.03)

                l1 = json.dumps({"room_pm25": air["room_pm25"], "room_pm10": air["room_pm10"]}, separators=(",", ":")) + "\n"
                d2 = {"city_pm25": air["city_pm25"], "city_pm10": air["city_pm10"], "time": air["time"]}
                if first_push:
                    d2["refresh"] = 1
                    first_push = False
                l2 = json.dumps(d2, separators=(",", ":")) + "\n"
                write_all(fd, l1.encode("ascii"))
                time.sleep(0.04)
                write_all(fd, l2.encode("ascii"))
                print(f"Sent to Nucleo: {l1.strip()} + {l2.strip()} (cal={len(cached_events)})", flush=True)
                last_push = now

            r, _, _ = select.select([fd], [], [], 1.0)
            if r:
                chunk = os.read(fd, 512)
                if not chunk:
                    raise OSError("Serial EOF")
                rx_buf += chunk
                while b"\n" in rx_buf:
                    line_b, rx_buf = rx_buf.split(b"\n", 1)
                    line = line_b.decode("utf-8", errors="replace").strip()
                    if not line:
                        continue
                    is_reading = line.startswith("{") and '"co2":' in line
                    # air_updated is the ack for every push - noise, not news.
                    if not is_reading and '"air_updated"' not in line:
                        print(f"From Nucleo: {line}", flush=True)
                    if is_reading:
                        try:
                            d = json.loads(line)
                            if time.time() - last_influx_write >= INFLUX_WRITE_INTERVAL_S:
                                write_influx_scd41(d["co2"], d["temp"], d["humidity"])
                                last_influx_write = time.time()
                                if not logged_first_reading:
                                    print(f"SCD41 -> InfluxDB: {line}", flush=True)
                                    logged_first_reading = True
                        except Exception as e:
                            print(f"Influx write error: {e}", flush=True)
                            # Retry on the next reading, not 30 s later.
                            last_influx_write = 0.0
        except Exception as e:
            print(f"Bridge loop error: {e}", flush=True)
            if fd is not None:
                try:
                    os.close(fd)
                except Exception:
                    pass
                fd = None
            time.sleep(3)


if __name__ == "__main__":
    main()
