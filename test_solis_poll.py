import json
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path

from solis_poll import (
    VERSION,
    Alarm,
    ConnectionHealth,
    DeviceInfo,
    Reading,
    Recorder,
    RecordingError,
    SolisClient,
    decode_bms_faults,
    decode_inverter_faults,
    decode_inverter_status,
    reading_from_record,
    sparkline,
    stream_payload,
)


class FakeResponse:
    def __init__(self, registers):
        self.registers = registers

    def isError(self):
        return False


class FakeModbusClient:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def read_input_registers(self, *, address, count, device_id):
        self.calls.append((address, count, device_id))
        return FakeResponse(self.responses[(address, count)])


def fake_solis(responses):
    client = SolisClient.__new__(SolisClient)
    client.client = FakeModbusClient(responses)
    client.slave = 1
    return client


class DecoderTests(unittest.TestCase):
    def test_version_is_available_without_connecting(self):
        result = subprocess.run(
            [sys.executable, "solis_poll.py", "--version"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.stdout.strip(), f"solis_poll.py {VERSION}")

    def test_inverter_status_labels_normal_and_unknown_alarm(self):
        self.assertEqual(decode_inverter_status(3), "Generating")
        self.assertEqual(decode_inverter_status(0x1015), "NO-Grid")
        self.assertEqual(decode_inverter_status(0x10FF), "Alarm 0x10FF")

    def test_inverter_fault_bits_are_decoded_in_register_order(self):
        alarms = decode_inverter_faults([0b11, 0, 0b10, 0, 0])
        self.assertEqual([alarm.code for alarm in alarms], ["1015", "1010", "1053"])

    def test_unknown_and_bms_bits_remain_actionable(self):
        inverter = decode_inverter_faults([1 << 15, 0, 0, 0, 0])[0]
        bms = decode_bms_faults([1 << 3, 0])[0]
        self.assertEqual(inverter.code, "INV.1.15")
        self.assertEqual(bms.code, "BMS1.3")
        self.assertIn("33145", bms.message)

    def test_sparkline_keeps_requested_width_and_range(self):
        graph, low, high = sparkline([1.0, 2.0, 3.0], 12)
        self.assertEqual(len(graph), 12)
        self.assertEqual((low, high), (1.0, 3.0))

    def test_stream_payload_is_versioned_and_json_serializable(self):
        reading = Reading(
            voltage=250.0,
            inverter_temperature_c=30.0,
            inverter_status_code=3,
            inverter_status="Generating",
            state_of_charge=93,
            house_load_kw=1.58,
            battery_kw=1.72,
            battery_status="Discharging",
            grid_kw=-0.5,
            grid_status="Importing",
            alarms=(Alarm("1015", "NO-Grid", "fault"),),
        )
        device = DeviceInfo(20, 101, 202, 301, 2001, True)
        health = ConnectionHealth(last_success_at=1_700_000_000.0, latency_ms=12.34)
        payload = stream_payload(
            reading,
            device,
            health,
            None,
            datetime.fromtimestamp(1_700_000_001.0).astimezone(),
        )

        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual(payload["reading"]["battery_flow_kw"], 1.72)
        self.assertEqual(payload["reading"]["alarms"][0]["severity"], "fault")
        self.assertEqual(payload["health"]["last_sample_age_s"], 1.0)
        json.dumps(payload)


class ModbusPollingTests(unittest.TestCase):
    def setUp(self):
        status = [0] * 16
        status[0] = 1
        status[4] = 93
        status[10] = 1 << 2
        status[12] = 1580
        status[14] = 0
        status[15] = 1720
        self.responses = {
            (33000, 4): [20, 101, 202, 301],
            (35000, 1): [2001],
            (33093, 3): [300, 5000, 3],
            (33116, 5): [0, 0, 0, 0, 0],
            (33035, 1): [125],
            (33073, 1): [2500],
            (33135, 16): status,
            (33263, 2): [0xFFFF, 0xFE0C],
            (33057, 2): [0, 2500],
        }

    def test_identification_and_polling_with_pv(self):
        client = fake_solis(self.responses)
        device = client.identify()
        slow = client.poll_slow(pv_enabled=True)
        reading = client.poll_fast(slow, pv_enabled=True)

        self.assertTrue(device.profile_validated)
        self.assertEqual(device.model_code, 20)
        self.assertEqual(reading.inverter_temperature_c, 30.0)
        self.assertEqual(reading.inverter_status, "Generating")
        self.assertEqual(reading.state_of_charge, 93)
        self.assertEqual(reading.house_load_kw, 1.58)
        self.assertEqual(reading.battery_kw, 1.72)
        self.assertEqual(reading.battery_status, "Discharging")
        self.assertEqual(reading.grid_kw, -0.5)
        self.assertEqual(reading.pv_kw, 2.5)
        self.assertEqual(reading.pv_today_kwh, 12.5)
        self.assertEqual(reading.alarms[0].code, "BMS1.2")

    def test_pv_registers_are_not_read_by_default(self):
        client = fake_solis(self.responses)
        slow = client.poll_slow(pv_enabled=False)
        reading = client.poll_fast(slow, pv_enabled=False)

        self.assertIsNone(reading.pv_kw)
        self.assertIsNone(reading.pv_today_kwh)
        calls = {(address, count) for address, count, _ in client.client.calls}
        self.assertNotIn((33035, 1), calls)
        self.assertNotIn((33057, 2), calls)


class RecorderTests(unittest.TestCase):
    def test_csv_and_jsonl_are_written_and_csv_restores_history(self):
        reading = Reading(
            voltage=250.0,
            inverter_temperature_c=30.0,
            inverter_status_code=3,
            inverter_status="Generating",
            state_of_charge=93,
            house_load_kw=1.58,
            battery_kw=1.72,
            battery_status="Discharging",
            grid_kw=-0.5,
            grid_status="Importing",
            alarms=(Alarm("2011", "MET_Comm_FAIL", "warning"),),
        )
        health = ConnectionHealth(latency_ms=12.3)
        with tempfile.TemporaryDirectory() as directory:
            csv_path = Path(directory) / "readings.csv"
            jsonl_path = Path(directory) / "readings.jsonl"
            recorder = Recorder(csv_path, jsonl_path)
            recorder.write(reading, health, datetime.now().astimezone())
            recorder.close()

            restored = Recorder(csv_path, None)
            history = restored.load_history(time.time())
            restored.close()

            self.assertEqual(len(history), 1)
            self.assertEqual(history[0][1].state_of_charge, 93)
            # Retained samples carry no alarms: the graphs never read them, and
            # an inverter reporting every fault bit made six hours cost 452 MB.
            self.assertEqual(history[0][1].alarms, ())
            self.assertIn("grid_voltage_v", csv_path.read_text())
            self.assertIn('"grid_voltage_v":250.0', jsonl_path.read_text())

    def test_recorded_alarms_round_trip_with_their_severity(self):
        record = {
            "timestamp": datetime.now().astimezone().isoformat(timespec="seconds"),
            "grid_voltage_v": 250.0,
            "inverter_temperature_c": 30.0,
            "inverter_status_code": 3,
            "inverter_status": "Generating",
            "battery_soc_percent": 93,
            "house_load_kw": 1.58,
            "battery_kw": 1.72,
            "battery_status": "Discharging",
            "grid_kw": -0.5,
            "grid_status": "Importing",
            "pv_kw": "",
            "pv_today_kwh": "",
            "alarms": "1041 ARC-FAULT; 2011 MET_Comm_FAIL; BMS1.2 active",
            "latency_ms": 1.0,
        }
        restored = reading_from_record(record)
        # Recordings store only the code and message, so severity has to be
        # looked back up rather than defaulted to a warning.
        self.assertEqual(
            [(alarm.code, alarm.severity) for alarm in restored.alarms],
            [("1041", "fault"), ("2011", "warning"), ("BMS1.2", "fault")],
        )

    def test_existing_csv_with_wrong_schema_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            csv_path = Path(directory) / "readings.csv"
            csv_path.write_text("wrong,header\n1,2\n")
            with self.assertRaisesRegex(RecordingError, "incompatible header"):
                Recorder(csv_path, None)


if __name__ == "__main__":
    unittest.main()
