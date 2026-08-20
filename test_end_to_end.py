"""End-to-end tests that run the real CLI against a fake Modbus inverter.

The unit tests in test_solis_poll.py call decoders directly. These drive
solis_poll.py as a subprocess so the parts that only exist in the main loop —
poll cadence, reconnect, the fatal-versus-transient decision, recording and
history restore — are covered without hardware.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
import unittest
from pathlib import Path

from fake_inverter import FakeInverter, hybrid_bank

MONITOR = str(Path(__file__).with_name("solis_poll.py"))
TIMEOUT = 30


def run_monitor(*arguments: str, timeout: int = TIMEOUT) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, MONITOR, *arguments],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def stream_samples(*arguments: str, wanted: int, timeout: int = TIMEOUT) -> list[dict]:
    """Collect at least `wanted` stream samples, then stop the monitor."""
    process = subprocess.Popen(
        [sys.executable, MONITOR, "--stream-json", *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    samples: list[dict] = []
    deadline = time.monotonic() + timeout
    try:
        assert process.stdout is not None
        while len(samples) < wanted and time.monotonic() < deadline:
            line = process.stdout.readline()
            if not line:
                break
            samples.append(json.loads(line))
    finally:
        process.terminate()
        process.wait(timeout=10)
        for pipe in (process.stdout, process.stderr):
            if pipe is not None:
                pipe.close()
    return samples


def readings(*arguments: str) -> dict[str, str]:
    result = run_monitor("--once", *arguments)
    assert result.returncode == 0, result.stderr
    return dict(line.split("=", 1) for line in result.stdout.strip().splitlines() if "=" in line)


class SingleReadingTests(unittest.TestCase):
    def test_once_decodes_the_whole_register_bank(self):
        with FakeInverter() as inverter:
            values = readings("--host", "127.0.0.1", "--port", str(inverter.port), "--pv")

        self.assertEqual(values["model_code"], "12695")
        self.assertEqual(values["inverter_status"], "Generating")
        self.assertEqual(values["grid_voltage_v"], "242.7")
        self.assertEqual(values["inverter_temperature_c"], "52.4")
        self.assertEqual(values["battery_soc_percent"], "78")
        self.assertEqual(values["house_load_kw"], "2.32")
        self.assertEqual(values["battery_status"], "Discharging")
        self.assertEqual(values["battery_kw"], "2.50")
        self.assertEqual(values["grid_status"], "Importing")
        self.assertEqual(values["grid_kw"], "-0.50")
        self.assertEqual(values["pv_kw"], "2.50")
        self.assertEqual(values["pv_today_kwh"], "12.5")

    def test_pv_registers_stay_untouched_without_the_flag(self):
        with FakeInverter() as inverter:
            values = readings("--host", "127.0.0.1", "--port", str(inverter.port))
        self.assertNotIn("pv_kw", values)


class StreamContractTests(unittest.TestCase):
    def test_stream_json_matches_the_documented_schema(self):
        with FakeInverter() as inverter:
            samples = stream_samples(
                "--host",
                "127.0.0.1",
                "--port",
                str(inverter.port),
                "--interval",
                "0.05",
                wanted=3,
            )

        self.assertGreaterEqual(len(samples), 3)
        sample = samples[-1]
        self.assertEqual(sample["schema_version"], 1)
        self.assertEqual(
            set(sample), {"schema_version", "timestamp", "device", "reading", "health", "error"}
        )
        self.assertEqual(sample["reading"]["battery_flow_kw"], sample["reading"]["battery_kw"])
        self.assertEqual(sample["health"]["rejected_samples"], 0)
        self.assertIsNone(sample["error"])
        self.assertTrue(sample["device"]["profile_validated"])


class TransientFaultTests(unittest.TestCase):
    def test_a_corrupt_frame_mid_run_does_not_end_the_process(self):
        """This exact case used to exit 1 after a single sample."""
        with FakeInverter(corrupt_after=8) as inverter:
            samples = stream_samples(
                "--host",
                "127.0.0.1",
                "--port",
                str(inverter.port),
                "--interval",
                "0.05",
                "--slow-interval",
                "30",
                wanted=12,
            )

        self.assertGreaterEqual(len(samples), 12)
        last = samples[-1]
        self.assertGreater(last["health"]["rejected_samples"], 0)
        self.assertIn("implausible sample discarded", last["error"])
        # The last good reading is retained rather than lost with the process.
        self.assertEqual(last["reading"]["house_load_kw"], 2.32)

    def test_an_implausible_first_sample_still_fails_fast(self):
        with FakeInverter(corrupt_after=0) as inverter:
            result = run_monitor("--host", "127.0.0.1", "--port", str(inverter.port), "--once")

        self.assertEqual(result.returncode, 1)
        self.assertIn("unsupported register map", result.stderr)
        self.assertIn("--skip-profile-check", result.stderr)

    def test_a_bad_first_sample_that_later_recovers_needs_the_override(self):
        """Without the flag the monitor cannot tell a bad map from a bad frame."""
        with FakeInverter(corrupt_until=6) as inverter:
            result = run_monitor("--host", "127.0.0.1", "--port", str(inverter.port), "--once")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unsupported register map", result.stderr)

        with FakeInverter(corrupt_until=6) as inverter:
            samples = stream_samples(
                "--host",
                "127.0.0.1",
                "--port",
                str(inverter.port),
                "--interval",
                "0.05",
                "--slow-interval",
                "30",
                "--skip-profile-check",
                wanted=4,
            )
        self.assertGreaterEqual(len(samples), 4)
        self.assertGreater(samples[-1]["health"]["successful_polls"], 0)
        self.assertEqual(samples[-1]["reading"]["battery_kw"], 2.5)

    def test_a_permanently_bad_register_is_reported_as_no_reading(self):
        """Not as an unsupported map: the override cannot invent a sample."""
        with FakeInverter(corrupt_after=0) as inverter:
            result = run_monitor(
                "--host",
                "127.0.0.1",
                "--port",
                str(inverter.port),
                "--once",
                "--skip-profile-check",
            )
        self.assertEqual(result.returncode, 1)
        self.assertIn("unable to obtain an inverter reading", result.stderr)

    def test_a_dropped_connection_reconnects(self):
        with FakeInverter(drop_after=10) as inverter:
            samples = stream_samples(
                "--host",
                "127.0.0.1",
                "--port",
                str(inverter.port),
                "--interval",
                "0.05",
                "--slow-interval",
                "30",
                wanted=14,
            )

        self.assertGreaterEqual(len(samples), 14)
        self.assertGreater(samples[-1]["health"]["reconnects"], 0)
        self.assertGreater(samples[-1]["health"]["successful_polls"], 1)


class ProfileRejectionTests(unittest.TestCase):
    def test_a_string_inverter_is_rejected_by_default(self):
        bank = hybrid_bank()
        bank[35000] = 0x1001
        with FakeInverter(bank) as inverter:
            result = run_monitor("--host", "127.0.0.1", "--port", str(inverter.port), "--once")

        self.assertEqual(result.returncode, 1)
        self.assertIn("string-inverter family", result.stderr)

    def test_a_string_inverter_can_be_forced(self):
        bank = hybrid_bank()
        bank[35000] = 0x1001
        with FakeInverter(bank) as inverter:
            values = readings(
                "--host", "127.0.0.1", "--port", str(inverter.port), "--skip-profile-check"
            )
        self.assertEqual(values["battery_soc_percent"], "78")

    def test_a_decimal_family_code_no_longer_rejects_a_hybrid(self):
        """1000-1099 used to hard-fail on a decimal reading of register 35000."""
        bank = hybrid_bank()
        bank[35000] = 1050
        with FakeInverter(bank) as inverter:
            values = readings("--host", "127.0.0.1", "--port", str(inverter.port))
        self.assertEqual(values["battery_soc_percent"], "78")


class RecordingTests(unittest.TestCase):
    def test_recorded_samples_are_restored_on_the_next_run(self):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            csv_path = Path(directory) / "readings.csv"
            with FakeInverter() as inverter:
                first = stream_samples(
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(inverter.port),
                    "--interval",
                    "0.05",
                    "--csv",
                    str(csv_path),
                    wanted=5,
                )
                self.assertGreaterEqual(len(first), 5)
                recorded = csv_path.read_text(encoding="utf-8").splitlines()
                self.assertEqual(recorded[0].split(",")[0], "timestamp")
                self.assertGreaterEqual(len(recorded), 6)

                # A second run must read that file back rather than start empty.
                result = run_monitor(
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(inverter.port),
                    "--once",
                    "--csv",
                    str(csv_path),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertGreater(
                len(csv_path.read_text(encoding="utf-8").splitlines()), len(recorded)
            )


if __name__ == "__main__":
    unittest.main()
