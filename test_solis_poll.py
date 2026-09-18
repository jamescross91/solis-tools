import json
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path

from pymodbus.exceptions import ModbusException

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
    def __init__(self, registers, exception_code=0):
        self.registers = registers
        self.exception_code = exception_code

    def isError(self):
        return self.exception_code != 0


class FakeModbusClient:
    """Serve a raw zero-based register bank the way a data logger would."""

    def __init__(
        self, bank, *, max_count=None, missing=(), glitch_wide_reads=0, refuse_wide_reads=0
    ):
        self.bank = bank
        self.max_count = max_count
        self.missing = set(missing)
        self.glitch_wide_reads = glitch_wide_reads
        self.refuse_wide_reads = refuse_wide_reads
        self.calls = []

    def read_input_registers(self, *, address, count, device_id):
        self.calls.append((address, count, device_id))
        addresses = range(address, address + count)
        if self.missing.intersection(addresses):
            return FakeResponse([], exception_code=2)
        if self.max_count is not None and count > self.max_count:
            return FakeResponse([], exception_code=3)
        if count > 16 and self.glitch_wide_reads > 0:
            self.glitch_wide_reads -= 1
            raise ModbusException("no response received")
        if count > 16 and self.refuse_wide_reads > 0:
            self.refuse_wide_reads -= 1
            return FakeResponse([], exception_code=0x0B)
        return FakeResponse([self.bank.get(register, 0) for register in addresses])


def fake_solis(bank, **behaviour):
    client = SolisClient("127.0.0.1", 502, 1, 1.0)
    client.client = FakeModbusClient(bank, **behaviour)
    return client


def covered_addresses(calls):
    covered = set()
    for address, count, _ in calls:
        covered.update(range(address, address + count))
    return covered


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
        self.bank = {
            33000: 20,
            33001: 101,
            33002: 202,
            33003: 301,
            35000: 2001,
            33035: 125,
            33057: 0,
            33058: 2500,
            33073: 2500,
            33093: 300,
            33094: 5000,
            33095: 3,
            33135: 1,
            33139: 93,
            33145: 1 << 2,
            33147: 1580,
            33149: 0,
            33150: 1720,
            33251: 2425,
            33263: 0xFFFF,
            33264: 0xFE0C,
        }

    def assert_full_reading(self, reading):
        self.assertEqual(reading.inverter_temperature_c, 30.0)
        self.assertEqual(reading.inverter_status, "Generating")
        self.assertEqual(reading.voltage, 250.0)
        self.assertEqual(reading.state_of_charge, 93)
        self.assertEqual(reading.house_load_kw, 1.58)
        self.assertEqual(reading.battery_kw, 1.72)
        self.assertEqual(reading.battery_status, "Discharging")
        self.assertEqual(reading.grid_kw, -0.5)
        self.assertEqual(reading.pv_kw, 2.5)
        self.assertEqual(reading.pv_today_kwh, 12.5)
        self.assertEqual(reading.alarms[0].code, "BMS1.2")

    def test_identification_and_polling_with_pv(self):
        client = fake_solis(self.bank)
        device = client.identify()
        slow = client.poll_slow(pv_enabled=True)
        reading = client.poll_fast(slow, pv_enabled=True)

        self.assertTrue(device.profile_validated)
        self.assertEqual(device.model_code, 20)
        self.assert_full_reading(reading)

    def test_each_poll_is_one_block_read_per_register_region(self):
        """Five fast reads and three slow ones used to be eight round trips."""
        client = fake_solis(self.bank)
        slow = client.poll_slow(pv_enabled=True)
        client.poll_fast(slow, pv_enabled=True, meter_voltage_enabled=True)
        client.poll_fast(slow, pv_enabled=True, meter_voltage_enabled=True)

        # Raw 33035-33120, 33057-33150, the one-off meter probe at 33251, then
        # 33251-33264; the second fast poll needs no probe.
        self.assertEqual(
            [(address, count) for address, count, _ in client.client.calls],
            [(33035, 86), (33057, 94), (33251, 1), (33251, 14), (33057, 94), (33251, 14)],
        )

    def test_pv_registers_are_not_read_by_default(self):
        client = fake_solis(self.bank)
        slow = client.poll_slow(pv_enabled=False)
        reading = client.poll_fast(slow, pv_enabled=False)

        self.assertIsNone(reading.pv_kw)
        self.assertIsNone(reading.pv_today_kwh)
        covered = covered_addresses(client.client.calls)
        self.assertNotIn(33035, covered)
        self.assertNotIn(33057, covered)
        self.assertNotIn(33058, covered)

    def test_a_logger_that_refuses_wide_reads_is_read_span_by_span(self):
        client = fake_solis(self.bank, max_count=20)
        for _ in range(SolisClient.BLOCK_FAILURES_BEFORE_NARROW):
            slow = client.poll_slow(pv_enabled=True)
            reading = client.poll_fast(slow, pv_enabled=True)
            self.assert_full_reading(reading)
        self.assertEqual(
            client.narrow_spans, {SolisClient.SLOW_PV_SPANS, SolisClient.FAST_PV_SPANS}
        )

        del client.client.calls[:]
        slow = client.poll_slow(pv_enabled=True)
        self.assert_full_reading(client.poll_fast(slow, pv_enabled=True))
        # Once the device has refused twice, no further wide attempt is made.
        self.assertEqual(
            [(address, count) for address, count, _ in client.client.calls],
            [(33035, 1), (33093, 3), (33116, 5), (33057, 2), (33073, 1), (33135, 16), (33263, 2)],
        )

    def test_a_transport_failure_propagates_and_keeps_coalescing(self):
        """Only a refusal says anything about the device's block support."""
        client = fake_solis(self.bank, glitch_wide_reads=1)
        with self.assertRaises(ModbusException):
            client.poll_slow(pv_enabled=True)
        self.assertEqual(len(client.client.calls), 1)
        self.assertEqual(client.block_failures, {})
        self.assertEqual(client.narrow_spans, set())

        del client.client.calls[:]
        client.poll_slow(pv_enabled=True)
        self.assertEqual([call[:2] for call in client.client.calls], [(33035, 86)])

    def test_one_refusal_falls_back_without_giving_up_coalescing(self):
        client = fake_solis(self.bank, refuse_wide_reads=1)
        slow = client.poll_slow(pv_enabled=True)
        self.assertEqual(slow.pv_today_kwh, 12.5)
        self.assertEqual(client.block_failures, {SolisClient.SLOW_PV_SPANS: 1})
        self.assertEqual(client.narrow_spans, set())

        del client.client.calls[:]
        client.poll_slow(pv_enabled=True)
        self.assertEqual([call[:2] for call in client.client.calls], [(33035, 86)])
        self.assertEqual(client.block_failures, {})

    def test_a_missing_meter_register_is_probed_once(self):
        del self.bank[33251]
        client = fake_solis(self.bank, missing={33251})
        slow = client.poll_slow(pv_enabled=False)
        for _ in range(3):
            reading = client.poll_fast(slow, pv_enabled=False, meter_voltage_enabled=True)
            self.assertIsNone(reading.meter_voltage_v)
            self.assertEqual(reading.grid_kw, -0.5)
        probes = [call for call in client.client.calls if 33251 in range(call[0], sum(call[:2]))]
        self.assertEqual(len(probes), 1)

    def test_meter_voltage_rides_in_the_grid_block(self):
        client = fake_solis(self.bank)
        slow = client.poll_slow(pv_enabled=False)
        reading = client.poll_fast(slow, pv_enabled=False, meter_voltage_enabled=True)
        self.assertEqual(reading.meter_voltage_v, 242.5)
        self.assertEqual(reading.grid_kw, -0.5)


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
