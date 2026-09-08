from __future__ import annotations

import json
import sqlite3
import tempfile
import time
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from solis_poll import ImportLimitActuator, Reading, VoltageControlRuntime, VoltageHistoryStore
from voltage_control import (
    ControlAction,
    ControllerJournal,
    DynamicVoltageConfiguration,
    DynamicVoltageController,
    ExportControlValidation,
    GridTelemetrySample,
    OperatingStateDetector,
    VoltageControlState,
    VoltageFilter,
    export_validation_path,
)


def sample(
    now: float,
    voltage: float = 220.0,
    grid_kw: float = -2.0,
    battery_status: str = "Charging",
    age_s: float = 0.0,
) -> GridTelemetrySample:
    return GridTelemetrySample(now, voltage, grid_kw, battery_status, age_s)


class ConfigurationTests(unittest.TestCase):
    def test_export_requires_the_installation_validation_gate(self):
        configuration = DynamicVoltageConfiguration(enabled=True, export_enabled=True)
        with self.assertRaisesRegex(ValueError, "blocked"):
            configuration.validate()

    def test_site_permission_caps_the_dynamic_export_maximum(self):
        configuration = DynamicVoltageConfiguration(
            maximum_export_w=12_000, site_export_permission_w=10_000
        )
        self.assertEqual(configuration.effective_maximum_export_w, 10_000)


class ExportControlValidationTests(unittest.TestCase):
    def evidence(self, **changes: object) -> dict[str, object]:
        value: dict[str, object] = {
            "device_identity": "inverter.local:502/1",
            "validated_at": "2026-09-07T12:00:00+01:00",
            "baseline_raw": 50,
            "test_raw": 30,
            "restored_raw": 50,
            "observed_before_kw": 4.638,
            "observed_limited_kw": 2.938,
            "schema_version": 1,
            "register_address": 43074,
            "watts_per_raw_unit": 100,
        }
        value.update(changes)
        return value

    def test_matching_restored_evidence_enables_export(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "validation.json"
            path.write_text(json.dumps(self.evidence()), encoding="utf-8")
            validation = ExportControlValidation.load(path, "inverter.local:502/1")
        self.assertIsNotNone(validation)
        self.assertEqual(validation.test_raw, 30)

    def test_missing_evidence_keeps_export_disabled(self):
        with tempfile.TemporaryDirectory() as directory:
            validation = ExportControlValidation.load(
                Path(directory) / "missing.json", "inverter.local:502/1"
            )
        self.assertIsNone(validation)

    def test_mismatched_endpoint_and_unrestored_baseline_fail_closed(self):
        for evidence, message in (
            (self.evidence(), "does not match"),
            (self.evidence(restored_raw=30), "restoration"),
        ):
            with self.subTest(message=message), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "validation.json"
                path.write_text(json.dumps(evidence), encoding="utf-8")
                identity = (
                    "other-inverter.local:502/1"
                    if message == "does not match"
                    else "inverter.local:502/1"
                )
                with self.assertRaisesRegex(ValueError, message):
                    ExportControlValidation.load(path, identity)

    def test_evidence_path_is_stable_and_scoped_to_endpoint(self):
        state = Path("state")
        first = export_validation_path(state, "inverter.local:502/1")
        second = export_validation_path(state, "other-inverter.local:502/1")
        self.assertEqual(first, export_validation_path(state, "inverter.local:502/1"))
        self.assertNotEqual(first, second)


class FilterAndStateTests(unittest.TestCase):
    def test_filter_moves_towards_new_samples_and_can_be_reset(self):
        voltage_filter = VoltageFilter(6)
        self.assertEqual(voltage_filter.update(220, 0), 220)
        filtered = voltage_filter.update(226, 6)
        self.assertGreater(filtered, 220)
        self.assertLess(filtered, 226)
        voltage_filter.reset()
        self.assertEqual(voltage_filter.update(215, 20), 215)

    def test_household_import_does_not_activate_without_battery_charging(self):
        configuration = DynamicVoltageConfiguration(enabled=True, activation_delay_s=1)
        detector = OperatingStateDetector(configuration)
        self.assertIsNone(detector.update(sample(0, battery_status="Idle")))
        self.assertIsNone(detector.update(sample(2, battery_status="Idle")))

    def test_sustained_grid_charging_activates_and_brief_transient_does_not(self):
        configuration = DynamicVoltageConfiguration(enabled=True, activation_delay_s=5)
        detector = OperatingStateDetector(configuration)
        self.assertIsNone(detector.update(sample(0)))
        self.assertIsNone(detector.update(sample(4)))
        self.assertEqual(detector.update(sample(5)), "import")

        detector.reset()
        self.assertIsNone(detector.update(sample(10)))
        self.assertIsNone(detector.update(sample(12, grid_kw=0, battery_status="Idle")))
        self.assertIsNone(detector.update(sample(20)))

    def test_deactivation_delay_prevents_zero_crossing_flap(self):
        configuration = DynamicVoltageConfiguration(
            enabled=True, activation_delay_s=0, deactivation_delay_s=10
        )
        detector = OperatingStateDetector(configuration)
        detector.update(sample(0))
        self.assertEqual(detector.update(sample(0)), "import")
        self.assertEqual(detector.update(sample(1, grid_kw=0)), "import")
        self.assertEqual(detector.update(sample(10, grid_kw=0)), "import")
        self.assertIsNone(detector.update(sample(11, grid_kw=0)))

    def test_deactivation_hysteresis_cannot_increase_power(self):
        configuration = DynamicVoltageConfiguration(
            enabled=True,
            activation_delay_s=0,
            deactivation_delay_s=10,
            filter_time_constant_s=0.01,
        )
        controller = DynamicVoltageController(configuration)
        controller.evaluate(sample(0, voltage=225), 10_000, 5_000)
        controller.evaluate(sample(0, voltage=225), 10_000, 5_000)
        decision = controller.evaluate(
            sample(1, voltage=225, grid_kw=0, battery_status="Idle"), 10_000, 5_000
        )
        self.assertEqual(decision.action, ControlAction.HOLDING)
        self.assertIn("deactivation delay", decision.reason)


class ControllerTests(unittest.TestCase):
    def controller(self, **changes: object) -> DynamicVoltageController:
        values = {
            "enabled": True,
            "activation_delay_s": 0,
            "settle_time_s": 5,
            "filter_time_constant_s": 0.01,
        }
        values.update(changes)
        return DynamicVoltageController(DynamicVoltageConfiguration(**values))

    def activated_decision(
        self,
        controller: DynamicVoltageController,
        current_w: int,
        voltage: float,
        now: float = 0,
    ):
        importing = sample(now, voltage, grid_kw=-current_w / 1_000)
        controller.evaluate(importing, current_w, 5_000)
        return controller.evaluate(importing, current_w, 5_000)

    def test_import_increases_holds_reduces_and_never_exceeds_maximum(self):
        controller = self.controller()
        decision = self.activated_decision(controller, 10_000, 220)
        self.assertEqual(decision.action, ControlAction.INCREASING)
        self.assertEqual(decision.desired_limit_w, 10_200)

        controller = self.controller()
        decision = self.activated_decision(controller, 10_000, 216.5)
        self.assertEqual(decision.action, ControlAction.HOLDING)

        controller = self.controller()
        decision = self.activated_decision(controller, 10_000, 215.6)
        self.assertEqual(decision.action, ControlAction.REDUCING)

        controller = self.controller(maximum_import_w=14_000)
        decision = self.activated_decision(controller, 14_000, 230)
        self.assertEqual(decision.desired_limit_w, 14_000)

    def test_import_allowance_is_latched_to_session_demand_plus_headroom(self):
        controller = self.controller(maximum_import_w=22_000, import_headroom_w=2_000)
        initial = sample(0, voltage=220, grid_kw=-12)
        controller.evaluate(initial, 10_000, 5_000)
        increase = controller.evaluate(initial, 10_000, 5_000)
        self.assertEqual(increase.desired_limit_w, 10_200)

        # Demand following the released allowance must not ratchet the session
        # ceiling beyond the 14 kW established from the initial 12 kW peak.
        at_ceiling = controller.evaluate(sample(10, voltage=220, grid_kw=-14), 14_000, 5_000)
        self.assertEqual(at_ceiling.action, ControlAction.HOLDING)
        self.assertEqual(at_ceiling.desired_limit_w, 14_000)
        self.assertIn("2 kW demand headroom", at_ceiling.reason)

    def test_import_ceiling_uses_peak_during_activation_delay(self):
        controller = self.controller(
            maximum_import_w=22_000,
            import_headroom_w=2_000,
            activation_delay_s=5,
        )
        controller.evaluate(sample(0, voltage=220, grid_kw=-12), 10_000, 5_000)
        controller.evaluate(sample(3, voltage=220, grid_kw=-10), 10_000, 5_000)
        decision = controller.evaluate(sample(5, voltage=220, grid_kw=-11), 14_000, 5_000)
        self.assertEqual(decision.action, ControlAction.HOLDING)
        self.assertEqual(decision.desired_limit_w, 14_000)

    def test_unused_import_allowance_is_trimmed_to_latched_ceiling(self):
        controller = self.controller(maximum_import_w=22_000, import_headroom_w=2_000)
        reported = sample(0, voltage=220, grid_kw=-12)
        controller.evaluate(reported, 22_000, 5_000)
        decision = controller.evaluate(reported, 22_000, 5_000)
        self.assertEqual(decision.action, ControlAction.REDUCING)
        self.assertEqual(decision.desired_limit_w, 14_000)
        self.assertIn("above measured import", decision.reason)

    def test_raw_boundary_causes_immediate_emergency_reduction(self):
        controller = DynamicVoltageController(DynamicVoltageConfiguration(enabled=True))
        decision = controller.evaluate(sample(0, 215), 10_000, 5_000)
        self.assertEqual(decision.state, VoltageControlState.EMERGENCY_LOW_VOLTAGE)
        self.assertTrue(decision.emergency)
        self.assertEqual(decision.desired_limit_w, 8_000)

    def test_settle_suppresses_increases_but_not_safety_reductions(self):
        controller = self.controller()
        self.activated_decision(controller, 10_000, 218)
        controller.command_applied("import", 10_000, 10_200, 218, 0)
        decision = controller.evaluate(sample(1, 218), 10_200, 5_000)
        self.assertEqual(decision.action, ControlAction.HOLDING)
        decision = controller.evaluate(sample(2, 215.5), 10_200, 5_000)
        self.assertEqual(decision.action, ControlAction.REDUCING)

    def test_stale_telemetry_never_increases_and_loss_requires_recovery_samples(self):
        controller = self.controller()
        self.activated_decision(controller, 10_000, 220)
        decision = controller.evaluate(sample(1, 220, age_s=5), 10_000, 5_000)
        self.assertEqual(decision.action, ControlAction.HOLDING)
        decision = controller.evaluate(sample(2, 220, age_s=7), 10_000, 5_000)
        self.assertEqual(decision.state, VoltageControlState.COMMUNICATION_UNAVAILABLE)
        self.assertEqual(
            controller.evaluate(sample(3), 10_000, 5_000).state, VoltageControlState.RECOVERING
        )
        self.assertEqual(
            controller.evaluate(sample(4), 10_000, 5_000).state, VoltageControlState.RECOVERING
        )
        self.assertNotEqual(
            controller.evaluate(sample(5), 10_000, 5_000).state, VoltageControlState.RECOVERING
        )

    def test_recent_voltage_response_updates_but_does_not_replace_safety(self):
        controller = self.controller(settle_time_s=1)
        self.activated_decision(controller, 10_000, 220)
        controller.command_applied("import", 10_000, 12_000, 220, 0, -2)
        controller.evaluate(sample(1, 216, grid_kw=-4), 12_000, 5_000)
        self.assertAlmostEqual(controller.sensitivity_v_per_kw or 0, 2.0)
        emergency = controller.evaluate(sample(2, 214.9), 12_000, 5_000)
        self.assertTrue(emergency.emergency)

    def test_export_controller_is_symmetric_but_requires_validation(self):
        controller = self.controller(
            import_enabled=False,
            export_enabled=True,
            export_control_validated=True,
            maximum_export_w=12_000,
            site_export_permission_w=10_000,
        )
        exporting = sample(0, voltage=250, grid_kw=2, battery_status="Idle")
        controller.evaluate(exporting, 10_000, 5_000)
        increase = controller.evaluate(exporting, 10_000, 5_000)
        self.assertEqual(increase.action, ControlAction.INCREASING)
        self.assertEqual(increase.desired_limit_w, 5_200)

        emergency = controller.evaluate(
            sample(1, voltage=258, grid_kw=2, battery_status="Idle"), 10_000, 5_000
        )
        self.assertEqual(emergency.state, VoltageControlState.EMERGENCY_HIGH_VOLTAGE)
        self.assertEqual(emergency.desired_limit_w, 3_000)


class FakeClient:
    def __init__(self):
        self.raw = 100
        self.export_raw = 50
        self.writes: list[int] = []

    def read_peak_shaving_limit_raw(self) -> int:
        return self.raw

    def set_peak_shaving_limit_raw(self, value: int) -> None:
        self.raw = value
        self.writes.append(value)

    def read_export_limit_raw(self) -> int:
        return self.export_raw

    def set_export_limit_raw(self, value: int, *, installation_validated: bool) -> None:
        if not installation_validated:
            raise PermissionError
        self.export_raw = value


def reading(grid_kw: float, battery_status: str) -> Reading:
    return Reading(
        voltage=220,
        meter_voltage_v=220,
        inverter_temperature_c=30,
        inverter_status_code=3,
        inverter_status="Generating",
        state_of_charge=50,
        house_load_kw=1,
        battery_kw=2,
        battery_status=battery_status,
        grid_kw=grid_kw,
        grid_status="Importing" if grid_kw < 0 else "Idle",
    )


class ActuatorAndPersistenceTests(unittest.TestCase):
    def test_quantisation_never_exceeds_bounds(self):
        client = FakeClient()
        actuator = ImportLimitActuator(client, 1_040, 13_960, 5)  # type: ignore[arg-type]
        actuator.capture()
        actuator.command(14_000, 0)
        self.assertEqual(client.raw, 139)
        actuator.command(0, 5)
        self.assertEqual(client.raw, 11)

    def test_sensitivity_expires_without_another_command(self):
        controller = DynamicVoltageController(DynamicVoltageConfiguration(enabled=True))
        controller.sensitivity_v_per_kw = 2
        controller.sensitivity_updated_at = 0
        controller._update_sensitivity(sample(1_000))
        self.assertIsNone(controller.sensitivity_v_per_kw)

    def test_ambiguous_write_reconciles_before_another_command(self):
        client = FakeClient()
        actuator = ImportLimitActuator(client, 1_000, 14_000, 5)  # type: ignore[arg-type]
        actuator.capture()
        with patch.object(
            client, "read_peak_shaving_limit_raw", side_effect=ConnectionError("lost reply")
        ):
            with self.assertRaises(ConnectionError):
                actuator.command(9_000, 0)
        self.assertEqual(actuator.uncertain_raw, 90)
        self.assertFalse(actuator.command(9_000, 1)[0])
        self.assertIsNone(actuator.uncertain_raw)
        self.assertEqual(client.writes, [90])

    def test_expired_voltage_during_capture_prevents_recovery_write(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "journal.json"
            ControllerJournal(path).start("old", 100, 50, 90, 50, "old")
            client = FakeClient()
            client.raw = 90
            runtime = VoltageControlRuntime(
                client, DynamicVoltageConfiguration(enabled=True), 5, path, None, 30
            )  # type: ignore[arg-type]
            runtime.last_meter_monotonic = time.monotonic() - 8
            with self.assertRaisesRegex(ConnectionError, "expired"):
                runtime.initialise(reading(0, "Idle"), time.monotonic())
            self.assertEqual(client.writes, [])
            runtime.shutdown()

    def test_sensitivity_ignores_limit_changes_without_measured_power_response(self):
        controller = DynamicVoltageController(
            DynamicVoltageConfiguration(enabled=True, settle_time_s=1)
        )
        controller.command_applied("import", 10_000, 12_000, 220, 0, -2)
        controller._update_sensitivity(sample(2, 218, grid_kw=-2))
        self.assertIsNone(controller.sensitivity_v_per_kw)

    def test_journal_rejects_wrong_device_and_concurrent_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "journal.json"
            first = ControllerJournal(path)
            first.start("session", 100, 50, 90, 50, "now")
            with self.assertRaisesRegex(ValueError, "identity"):
                ControllerJournal(path, "different-inverter").load()
            first.acquire_lock()
            try:
                with self.assertRaisesRegex(RuntimeError, "already owns"):
                    ControllerJournal(path).acquire_lock()
            finally:
                first.close()
            second = ControllerJournal(path)
            second.acquire_lock()
            second.close()

    def test_stale_meter_blocks_initialisation_even_with_fresh_envelope(self):
        with tempfile.TemporaryDirectory() as directory:
            client = FakeClient()
            runtime = VoltageControlRuntime(
                client,
                DynamicVoltageConfiguration(enabled=True),
                5,
                Path(directory) / "journal.json",
                None,
                30,
            )  # type: ignore[arg-type]
            stale = replace(reading(0, "Idle"), meter_sample_monotonic=time.monotonic() - 7)
            decision = runtime.update(stale, time.monotonic(), time.time())
            self.assertEqual(decision.state, VoltageControlState.COMMUNICATION_UNAVAILABLE)
            self.assertFalse(runtime.initialised)
            self.assertEqual(client.writes, [])
            self.assertIsNone(runtime.stream_dict(time.monotonic())["daily_summary"])
            runtime.shutdown()

    def test_shutdown_during_communication_loss_retains_recovery_journal(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "journal.json"
            client = FakeClient()
            runtime = VoltageControlRuntime(
                client, DynamicVoltageConfiguration(enabled=True), 5, path, None, 30
            )  # type: ignore[arg-type]
            runtime.update(reading(0, "Idle"), time.monotonic(), time.time())
            runtime.import_actuator.command(9_000, time.monotonic())
            runtime.communication_unavailable()
            messages = runtime.shutdown()
            self.assertEqual(client.raw, 90)
            self.assertIn("deferred", messages[0])
            self.assertFalse(ControllerJournal(path).load()["clean_shutdown"])

    def test_accepted_write_lost_response_is_recovered_after_crash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "journal.json"
            client = FakeClient()
            runtime = VoltageControlRuntime(
                client, DynamicVoltageConfiguration(enabled=True), 5, path, None, 30
            )  # type: ignore[arg-type]
            runtime.update(reading(0, "Idle"), time.monotonic(), time.time())
            with patch.object(
                client, "read_peak_shaving_limit_raw", side_effect=ConnectionError("lost reply")
            ):
                with self.assertRaises(ConnectionError):
                    runtime.import_actuator.command(9_000, time.monotonic())
            self.assertEqual(client.raw, 90)
            self.assertEqual(ControllerJournal(path).load()["pending_import_raw"], 90)
            self.assertEqual(runtime.import_actuator.total_write_count, 1)
            runtime.journal.close()  # A crashed process releases the operating-system lock.
            recovered = VoltageControlRuntime(
                client, DynamicVoltageConfiguration(enabled=True), 5, path, None, 30
            )  # type: ignore[arg-type]
            recovered.update(reading(0, "Idle"), time.monotonic(), time.time())
            self.assertEqual(client.raw, 100)
            recovered.shutdown()

    def test_crash_before_transmission_and_active_baseline_ceiling(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "journal.json"
            journal = ControllerJournal(path)
            value = journal.start("old", 100, 50, 90, 50, "old")
            journal.prepare_command(value, "import", 80)
            client = FakeClient()
            client.raw = 90
            runtime = VoltageControlRuntime(
                client, DynamicVoltageConfiguration(enabled=True), 5, path, None, 30
            )  # type: ignore[arg-type]
            runtime.update(reading(-2, "Charging"), time.monotonic(), time.time())
            self.assertEqual(client.raw, 90)
            self.assertEqual(runtime.import_actuator.maximum_w, 10_000)
            runtime.import_actuator.command(14_000, time.monotonic())
            self.assertEqual(client.raw, 100)
            runtime.shutdown()

    def test_history_batches_transactions_and_flushes_on_close(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.sqlite3"
            store = VoltageHistoryStore(path)
            decision = DynamicVoltageController(DynamicVoltageConfiguration()).decision
            store.record_sample(60, 220, -2, 10_000, decision)
            store.record_sample(62, 218, -3, 9_500, decision)
            observer = sqlite3.connect(path)
            self.assertEqual(
                observer.execute("SELECT sample_count FROM voltage_minutes").fetchone()[0], 1
            )
            store.close()
            self.assertEqual(
                observer.execute("SELECT sample_count FROM voltage_minutes").fetchone()[0], 2
            )
            observer.close()

    def test_import_actuator_scales_deduplicates_rate_limits_and_restores(self):
        client = FakeClient()
        actuator = ImportLimitActuator(client, 1_000, 14_000, 5)  # type: ignore[arg-type]
        actuator.capture()
        self.assertEqual(actuator.commanded_w, 10_000)
        self.assertEqual(actuator.command(10_200, 0), (True, "write acknowledged"))
        self.assertFalse(actuator.command(10_200, 1)[0])
        self.assertFalse(actuator.command(10_400, 1)[0])
        self.assertTrue(actuator.command(10_400, 1, emergency=True)[0])
        self.assertEqual(actuator.restore(2), (True, "captured baseline restored"))
        self.assertEqual(client.writes, [102, 104, 100])

    def test_restore_does_not_overwrite_an_external_change(self):
        client = FakeClient()
        actuator = ImportLimitActuator(client, 1_000, 14_000, 5)  # type: ignore[arg-type]
        actuator.capture()
        actuator.command(9_000, 0)
        client.raw = 110
        changed, message = actuator.restore(10)
        self.assertFalse(changed)
        self.assertIn("external modification", message)
        self.assertEqual(client.raw, 110)

    def test_minute_history_aggregates_and_records_events(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.sqlite3"
            store = VoltageHistoryStore(path)
            controller = DynamicVoltageController(DynamicVoltageConfiguration())
            decision = controller.decision
            store.record_sample(60, 220, -2, 10_000, decision)
            store.record_sample(62, 218, -3, 9_500, decision)
            event = store.record_event(
                __import__("datetime").datetime.now().astimezone(),
                decision,
                -3,
                9_500,
                10_000,
            )
            store.close()
            database = sqlite3.connect(path)
            row = database.execute(
                "SELECT voltage_min, voltage_max, sample_count FROM voltage_minutes"
            ).fetchone()
            events = database.execute("SELECT count(*) FROM voltage_events").fetchone()
            database.close()
            self.assertEqual(row, (218.0, 220.0, 2))
            self.assertEqual(events, (1,))
            self.assertEqual(event["previous_limit_w"], 10_000)
            self.assertEqual(event["limit_delta_w"], -500)

    def test_crash_journal_round_trips_and_marks_clean(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "journal.json"
            journal = ControllerJournal(path)
            value = journal.start("session", 140, 50, 100, 50, "start")
            journal.update_command(value, "import", 90, "changed")
            recovered = journal.load()
            self.assertEqual(recovered["last_commanded_import_raw"], 90)  # type: ignore[index]
            self.assertFalse(recovered["clean_shutdown"])  # type: ignore[index]
            journal.mark_clean(value, "stopped")
            self.assertTrue(journal.load()["clean_shutdown"])  # type: ignore[index]

    def test_unclean_idle_restart_restores_owned_import_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            journal_path = Path(directory) / "journal.json"
            ControllerJournal(journal_path).start("old", 140, 50, 90, 50, "old")
            client = FakeClient()
            client.raw = 90
            runtime = VoltageControlRuntime(  # type: ignore[arg-type]
                client,
                DynamicVoltageConfiguration(enabled=True),
                5,
                journal_path,
                None,
                30,
            )
            runtime.update(reading(0, "Idle"), time.monotonic(), time.time())
            self.assertEqual(client.raw, 140)
            self.assertIn("restored import baseline", runtime.recovery_note or "")
            runtime.shutdown()

    def test_unclean_active_restart_keeps_conservative_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            journal_path = Path(directory) / "journal.json"
            ControllerJournal(journal_path).start("old", 140, 50, 90, 50, "old")
            client = FakeClient()
            client.raw = 90
            runtime = VoltageControlRuntime(  # type: ignore[arg-type]
                client,
                DynamicVoltageConfiguration(enabled=True),
                5,
                journal_path,
                None,
                30,
            )
            runtime.update(reading(-2, "Charging"), time.monotonic(), time.time())
            self.assertEqual(client.raw, 90)
            self.assertEqual(runtime.import_actuator.baseline_raw, 140)
            self.assertIn("resumed conservative import", runtime.recovery_note or "")
            runtime.shutdown()


if __name__ == "__main__":
    unittest.main()
