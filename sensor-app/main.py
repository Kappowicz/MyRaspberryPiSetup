import os
import time
import serial
from influxdb_client import InfluxDBClient, Point
from influxdb_client.client.write_api import SYNCHRONOUS

INFLUXDB_URL = os.getenv("INFLUXDB_URL", "http://influxdb:8086")
INFLUXDB_TOKEN = os.getenv("INFLUXDB_TOKEN", "YOUR_TOKEN_HERE")
INFLUXDB_ORG = os.getenv("INFLUXDB_ORG", "your_organisation")
INFLUXDB_BUCKET = os.getenv("INFLUXDB_BUCKET", "sensors")
# Tag for this sensor's own readings; the dashboard filters on it.
SENSOR_LOCATION = os.getenv("SENSOR_LOCATION", "home")
SERIAL_PORT = os.getenv("SERIAL_PORT", "/dev/ttyUSB0")

# Magic hex command frames for the SDS011
CMD_WAKE = b'\xaa\xb4\x06\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\x06\xab'
CMD_SLEEP = b'\xaa\xb4\x06\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\x05\xab'


def open_serial_port():
    print(f"Opening port: {SERIAL_PORT}")
    return serial.Serial(SERIAL_PORT, baudrate=9600, stopbits=1, parity="N", timeout=2)


def read_sensor_data(ser):
    # Flush the buffer so we do not read stale rubbish left in the port
    ser.reset_input_buffer()

    # Try to read a frame at most 5 times
    for _ in range(5):
        data = ser.read(10)
        if len(data) == 10 and data[0] == 0xAA and data[1] == 0xC0 and data[9] == 0xAB:
            checksum = sum(data[2:8]) & 0xFF
            if checksum == data[8]:
                pm25 = ((data[3] * 256) + data[2]) / 10.0
                pm10 = ((data[5] * 256) + data[4]) / 10.0
                return pm25, pm10
    return None, None


def run_cycle(ser, write_api):
    """Run one wake -> settle -> read -> write -> sleep cycle.

    Always attempts to send CMD_SLEEP in finally so an InfluxDB error never
    leaves the SDS011 fan and laser running continuously.
    """
    print("\n--- starting a measurement cycle ---")
    print("Waking the SDS011 sensor...")
    ser.write(CMD_WAKE)
    try:
        # Wait 15 seconds for the measurement chamber to flush through
        print("Waiting 15s for the reading to settle...")
        time.sleep(15)

        pm25, pm10 = read_sensor_data(ser)
        if pm25 is not None and pm10 is not None:
            print(f"SUCCESS! Read PM2.5: {pm25} ug/m3, PM10: {pm10} ug/m3")
            point = (
                Point("air_quality")
                .tag("sensor", "SDS011")
                .tag("location", SENSOR_LOCATION)
                .field("pm25", float(pm25))
                .field("pm10", float(pm10))
            )
            write_api.write(bucket=INFLUXDB_BUCKET, record=point)
        else:
            print("Failed to read from the sensor in this cycle.")
    finally:
        print("Putting the sensor to sleep...")
        try:
            ser.write(CMD_SLEEP)
        except Exception as sleep_err:
            print(f"Warning: failed to send sleep command: {sleep_err}")
            raise


def main():
    print("Initialising the InfluxDB connection...")
    client = InfluxDBClient(url=INFLUXDB_URL, token=INFLUXDB_TOKEN, org=INFLUXDB_ORG)
    write_api = client.write_api(write_options=SYNCHRONOUS)

    ser = None
    while True:
        try:
            if ser is None or not getattr(ser, "is_open", False):
                ser = open_serial_port()

            run_cycle(ser, write_api)

            # Rest before the next measurement (10 minutes = 600 seconds).
            # We subtract the 15 seconds spent measuring so the cycle stays
            # exactly 10 minutes.
            print("Waiting for the next cycle (10 minutes)...")
            time.sleep(585)
        except serial.SerialException as e:
            print(f"Serial error in the main loop: {e}")
            if ser is not None:
                try:
                    ser.close()
                except Exception:
                    pass
                ser = None
            time.sleep(30)
        except Exception as e:
            print(f"Error in the main loop: {e}")
            time.sleep(30)  # on error, pause briefly so we do not flood the logs


if __name__ == "__main__":
    main()
