"""Closed-loop dynamic grid-voltage control independent of Modbus and UI code."""

from __future__ import annotations

import fcntl
import hashlib
import json
import math
import os
import tempfile
from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import Path
from typing import Any


class VoltageControlState(str, Enum):
    DISABLED = "Disabled"
    STANDBY = "Standby"
    GRID_CHARGING = "Grid charging"
    IMPORT_REGULATING = "Import regulating"
    EXPORTING = "Exporting"
    EXPORT_REGULATING = "Export regulating"
    EMERGENCY_LOW_VOLTAGE = "Emergency low voltage"
    EMERGENCY_HIGH_VOLTAGE = "Emergency high voltage"
    COMMUNICATION_UNAVAILABLE = "Communication unavailable"
    RECOVERING = "Recovery / observing"
    UNSUPPORTED = "Unsupported"
    SUSPENDED = "Suspended"


class ControlAction(str, Enum):
    DISABLED = "Disabled"
    STANDBY = "Standby"
    INCREASING = "Increasing"
    HOLDING = "Holding"
    REDUCING = "Reducing"
    EMERGENCY = "Emergency"
    SUSPENDED = "Suspended"


@dataclass(frozen=True)
class DynamicVoltageConfiguration:
    enabled: bool = False
    import_enabled: bool = True
    export_enabled: bool = False
    export_control_validated: bool = False
    minimum_voltage_v: float = 215.0
    maximum_voltage_v: float = 258.0
    safety_margin_v: float = 1.5
    deadband_v: float = 0.75
    maximum_import_w: int = 14_000
    maximum_export_w: int = 10_000
    site_export_permission_w: int = 10_000
    minimum_import_w: int = 1_000
    import_headroom_w: int = 2_000
    increase_step_w: int = 200
    reduction_step_w: int = 500
    near_limit_reduction_w: int = 1_000
    emergency_reduction_w: int = 2_000
    settle_time_s: float = 5.0
    activation_delay_s: float = 5.0
    deactivation_delay_s: float = 10.0
    import_activation_w: int = 1_000
    export_activation_w: int = 500
    fresh_age_s: float = 4.0
    stale_age_s: float = 6.0
    recovery_samples: int = 3
    filter_time_constant_s: float = 6.0

    def validate(self) -> None:
        numeric = (
            self.minimum_voltage_v,
            self.maximum_voltage_v,
            self.safety_margin_v,
            self.deadband_v,
            self.settle_time_s,
            self.activation_delay_s,
            self.deactivation_delay_s,
            self.fresh_age_s,
            self.stale_age_s,
            self.filter_time_constant_s,
        )
        if any(not math.isfinite(value) for value in numeric):
            raise ValueError("dynamic-voltage settings must be finite")
        if not 180 <= self.minimum_voltage_v < self.maximum_voltage_v <= 280:
            raise ValueError("voltage limits must satisfy 180 <= minimum < maximum <= 280")
        if self.safety_margin_v <= 0 or self.deadband_v <= 0:
            raise ValueError("safety margin and deadband must be above zero")
        if (
            self.settle_time_s < 0
            or self.activation_delay_s < 0
            or self.deactivation_delay_s < 0
            or self.fresh_age_s < 0
            or self.stale_age_s <= 0
            or self.filter_time_constant_s <= 0
        ):
            raise ValueError("control timing settings must be non-negative")
        if self.minimum_voltage_v + self.safety_margin_v >= self.maximum_voltage_v:
            raise ValueError("the voltage safety margin leaves no operating range")
        if self.fresh_age_s > self.stale_age_s:
            raise ValueError("fresh telemetry age cannot exceed the stale threshold")
        powers = (
            self.maximum_import_w,
            self.maximum_export_w,
            self.site_export_permission_w,
            self.minimum_import_w,
            self.import_headroom_w,
            self.increase_step_w,
            self.reduction_step_w,
            self.near_limit_reduction_w,
            self.emergency_reduction_w,
            self.import_activation_w,
            self.export_activation_w,
        )
        if any(value < 0 for value in powers):
            raise ValueError("dynamic-voltage power settings cannot be negative")
        if any(
            value < 100
            for value in (
                self.increase_step_w,
                self.reduction_step_w,
                self.near_limit_reduction_w,
                self.emergency_reduction_w,
            )
        ):
            raise ValueError("control power steps must be at least 100 W")
        if self.maximum_import_w > 0xFFFF * 100 or self.maximum_export_w > 0xFFFF * 100:
            raise ValueError("controller power limits exceed uint16 register capacity")
        if not 1_000 <= self.minimum_import_w <= self.maximum_import_w:
            raise ValueError("minimum import must be at least 1 kW and no greater than maximum")
        if self.recovery_samples < 1:
            raise ValueError("recovery sample count must be at least one")
        if self.export_enabled and not self.export_control_validated:
            raise ValueError("dynamic export is blocked until this installation is validated")

    @property
    def import_target_v(self) -> float:
        return self.minimum_voltage_v + self.safety_margin_v

    @property
    def export_target_v(self) -> float:
        return self.maximum_voltage_v - self.safety_margin_v

    @property
    def effective_maximum_export_w(self) -> int:
        return min(self.maximum_export_w, self.site_export_permission_w)


@dataclass(frozen=True)
class ExportControlValidation:
    """Evidence that the export actuator was tested and restored on one endpoint."""

    device_identity: str
    validated_at: str
    baseline_raw: int
    test_raw: int
    restored_raw: int
    observed_before_kw: float
    observed_limited_kw: float
    schema_version: int = 1
    register_address: int = 43074
    watts_per_raw_unit: int = 100

    @classmethod
    def load(cls, path: Path, device_identity: str) -> ExportControlValidation | None:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError(f"export-control validation record cannot be read: {exc}") from exc
        if not isinstance(value, dict):
            raise ValueError("export-control validation record must be a JSON object")
        try:
            validation = cls(**value)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"export-control validation record is invalid: {exc}") from exc
        try:
            validation.validate(device_identity)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"export-control validation record is invalid: {exc}") from exc
        return validation

    def validate(self, device_identity: str) -> None:
        integer_values = (
            self.schema_version,
            self.register_address,
            self.watts_per_raw_unit,
            self.baseline_raw,
            self.test_raw,
            self.restored_raw,
        )
        if any(type(value) is not int for value in integer_values):
            raise ValueError("export-control validation register values must be integers")
        if not isinstance(self.validated_at, str) or not self.validated_at.strip():
            raise ValueError("export-control validation timestamp is missing")
        if any(
            type(value) not in (int, float)
            for value in (self.observed_before_kw, self.observed_limited_kw)
        ):
            raise ValueError("export-control validation observations must be numbers")
        if self.schema_version != 1:
            raise ValueError("export-control validation schema is unsupported")
        if self.device_identity != device_identity:
            raise ValueError("export-control validation does not match this inverter endpoint")
        if self.register_address != 43074 or self.watts_per_raw_unit != 100:
            raise ValueError("export-control validation has the wrong register semantics")
        if not 0 <= self.test_raw < self.baseline_raw <= 0xFFFF:
            raise ValueError("export-control validation limits do not prove a reduction")
        if self.restored_raw != self.baseline_raw:
            raise ValueError("export-control validation does not prove baseline restoration")
        if not all(
            math.isfinite(value) for value in (self.observed_before_kw, self.observed_limited_kw)
        ):
            raise ValueError("export-control validation observations must be finite")
        if self.observed_limited_kw < 0:
            raise ValueError("export-control validation limited observation must be export")
        expected_limit_kw = self.test_raw * self.watts_per_raw_unit / 1_000
        if self.observed_before_kw <= expected_limit_kw:
            raise ValueError("export-control validation did not begin above the test limit")
        if self.observed_limited_kw > expected_limit_kw + 0.2:
            raise ValueError("export-control validation did not observe the requested limit")


def export_validation_path(state_directory: Path, device_identity: str) -> Path:
    device_key = hashlib.sha256(device_identity.encode()).hexdigest()[:24]
    return state_directory / f"export-control-validation-{device_key}.json"


@dataclass(frozen=True)
class GridTelemetrySample:
    monotonic_s: float
    raw_voltage_v: float
    grid_kw: float
    battery_status: str
    age_s: float = 0.0


@dataclass(frozen=True)
class ControlDecision:
    state: VoltageControlState
    action: ControlAction
    mode: str | None
    desired_limit_w: int | None
    raw_voltage_v: float | None
    filtered_voltage_v: float | None
    reason: str
    emergency: bool = False

    def stream_dict(self) -> dict[str, Any]:
        return {
            "state": self.state.value,
            "action": self.action.value,
            "mode": self.mode,
            "desired_limit_w": self.desired_limit_w,
            "raw_voltage_v": self.raw_voltage_v,
            "filtered_voltage_v": self.filtered_voltage_v,
            "reason": self.reason,
            "emergency": self.emergency,
        }


class VoltageFilter:
    """Time-aware EWMA that rebuilds cleanly after communications loss."""

    maximum_sample_step_v = 4.0

    def __init__(self, time_constant_s: float):
        self.time_constant_s = time_constant_s
        self.value: float | None = None
        self.updated_at: float | None = None

    def reset(self) -> None:
        self.value = None
        self.updated_at = None

    def update(self, value: float, now: float) -> float:
        if self.value is None or self.updated_at is None or now <= self.updated_at:
            self.value = value
        else:
            elapsed = now - self.updated_at
            alpha = 1 - math.exp(-elapsed / self.time_constant_s)
            # Raw voltage still drives emergency action. Winsorising only the
            # optimiser's filtered input prevents one corrupt-but-plausible
            # sample from moving its working target by tens of volts.
            bounded = min(
                self.value + self.maximum_sample_step_v,
                max(self.value - self.maximum_sample_step_v, value),
            )
            self.value += alpha * (bounded - self.value)
        self.updated_at = now
        return self.value


class OperatingStateDetector:
    """Debounce import/export activation and deactivation around noisy zero flow."""

    def __init__(self, configuration: DynamicVoltageConfiguration):
        self.configuration = configuration
        self.mode: str | None = None
        self.candidate: str | None = None
        self.candidate_since: float | None = None
        self.inactive_since: float | None = None

    def reset(self) -> None:
        self.mode = None
        self.candidate = None
        self.candidate_since = None
        self.inactive_since = None

    def _candidate(self, sample: GridTelemetrySample) -> str | None:
        importing = (
            self.configuration.import_enabled
            and sample.grid_kw * -1_000 >= self.configuration.import_activation_w
            and sample.battery_status == "Charging"
        )
        exporting = (
            self.configuration.export_enabled
            and self.configuration.export_control_validated
            and sample.grid_kw * 1_000 >= self.configuration.export_activation_w
        )
        if importing:
            return "import"
        if exporting:
            return "export"
        return None

    def update(self, sample: GridTelemetrySample) -> str | None:
        candidate = self._candidate(sample)
        now = sample.monotonic_s
        if self.mode is not None:
            if candidate == self.mode:
                self.inactive_since = None
                return self.mode
            if self.inactive_since is None:
                self.inactive_since = now
            if now - self.inactive_since < self.configuration.deactivation_delay_s:
                return self.mode
            self.mode = None
            self.inactive_since = None
            self.candidate = None
            self.candidate_since = None

        if candidate is None:
            self.candidate = None
            self.candidate_since = None
            return None
        if candidate != self.candidate:
            self.candidate = candidate
            self.candidate_since = now
            return None
        if self.candidate_since is None:
            self.candidate_since = now
            return None
        if now - self.candidate_since >= self.configuration.activation_delay_s:
            self.mode = candidate
            self.inactive_since = None
        return self.mode


@dataclass
class _SensitivityObservation:
    mode: str
    old_w: int
    new_w: int
    voltage_v: float
    commanded_at: float
    grid_kw: float


class DynamicVoltageController:
    """Discover the current safe power limit without assuming a fixed grid model."""

    def __init__(self, configuration: DynamicVoltageConfiguration):
        configuration.validate()
        self.configuration = configuration
        self.filter = VoltageFilter(configuration.filter_time_constant_s)
        self.detector = OperatingStateDetector(configuration)
        self.decision = ControlDecision(
            VoltageControlState.DISABLED
            if not configuration.enabled
            else VoltageControlState.STANDBY,
            ControlAction.DISABLED if not configuration.enabled else ControlAction.STANDBY,
            None,
            None,
            None,
            None,
            "dynamic voltage control is disabled" if not configuration.enabled else "observing",
        )
        self.settle_until = 0.0
        self.recovering = False
        self.recovery_count = 0
        self.sensitivity_v_per_kw: float | None = None
        self.sensitivity_updated_at: float | None = None
        self.pending_observation: _SensitivityObservation | None = None
        self.import_demand_ceiling_w: int | None = None
        self.import_activation_peak_w = 0

    def communication_unavailable(self) -> ControlDecision:
        self.recovering = True
        self.recovery_count = 0
        self.filter.reset()
        self.detector.reset()
        self.pending_observation = None
        self.decision = ControlDecision(
            VoltageControlState.COMMUNICATION_UNAVAILABLE,
            ControlAction.SUSPENDED,
            None,
            None,
            None,
            None,
            "telemetry is unavailable; optimisation writes are frozen",
        )
        return self.decision

    def command_applied(
        self,
        mode: str,
        old_w: int,
        new_w: int,
        voltage_v: float,
        now: float,
        grid_kw: float | None = None,
    ) -> None:
        self.settle_until = now + self.configuration.settle_time_s
        if old_w != new_w and grid_kw is not None:
            self.pending_observation = _SensitivityObservation(
                mode, old_w, new_w, voltage_v, now, grid_kw
            )

    def _update_sensitivity(self, sample: GridTelemetrySample) -> None:
        if (
            self.sensitivity_updated_at is not None
            and sample.monotonic_s - self.sensitivity_updated_at > 300
        ):
            self.sensitivity_v_per_kw = None
            self.sensitivity_updated_at = None
        pending = self.pending_observation
        if pending is not None and (
            self.detector._candidate(sample) != pending.mode
            or sample.age_s > self.configuration.fresh_age_s
            or sample.monotonic_s - pending.commanded_at > 60
        ):
            self.pending_observation = None
            return
        if (
            pending is None
            or sample.monotonic_s < pending.commanded_at + self.configuration.settle_time_s
        ):
            return
        delta_kw = sample.grid_kw - pending.grid_kw
        delta_voltage = sample.raw_voltage_v - pending.voltage_v
        expected_direction = (pending.new_w - pending.old_w) * (
            -1 if pending.mode == "import" else 1
        )
        if (
            abs(delta_kw) >= 0.1
            and delta_kw * expected_direction > 0
            and delta_voltage * delta_kw > 0
        ):
            observed = delta_voltage / delta_kw
            if 0.01 <= observed <= 25:
                self.sensitivity_v_per_kw = (
                    observed
                    if self.sensitivity_v_per_kw is None
                    else 0.7 * self.sensitivity_v_per_kw + 0.3 * observed
                )
                self.sensitivity_updated_at = sample.monotonic_s
        self.pending_observation = None

    def _increase_step(self, voltage_headroom_v: float) -> int:
        step = self.configuration.increase_step_w
        if self.sensitivity_v_per_kw:
            adaptive = int((voltage_headroom_v / self.sensitivity_v_per_kw) * 500)
            step = min(step, max(100, adaptive))
        return max(100, (step // 100) * 100)

    def evaluate(
        self,
        sample: GridTelemetrySample,
        current_import_w: int,
        current_export_w: int,
    ) -> ControlDecision:
        configuration = self.configuration
        if not configuration.enabled:
            return self.decision
        if sample.age_s > configuration.stale_age_s:
            return self.communication_unavailable()

        filtered = self.filter.update(sample.raw_voltage_v, sample.monotonic_s)
        self._update_sensitivity(sample)
        immediate_mode = self.detector._candidate(sample)
        if immediate_mode == "import" and self.import_demand_ceiling_w is None:
            self.import_activation_peak_w = max(
                self.import_activation_peak_w,
                max(0, round(-sample.grid_kw * 1_000)),
            )
        if immediate_mode == "import" and sample.raw_voltage_v <= configuration.minimum_voltage_v:
            self.decision = self._evaluate_import(sample, filtered, current_import_w)
            return self.decision
        if immediate_mode == "export" and sample.raw_voltage_v >= configuration.maximum_voltage_v:
            self.decision = self._evaluate_export(sample, filtered, current_export_w)
            return self.decision
        if self.recovering:
            self.recovery_count = (
                self.recovery_count + 1 if sample.age_s <= configuration.fresh_age_s else 0
            )
            if self.recovery_count < configuration.recovery_samples:
                self.decision = ControlDecision(
                    VoltageControlState.RECOVERING,
                    ControlAction.SUSPENDED,
                    None,
                    None,
                    sample.raw_voltage_v,
                    filtered,
                    f"observing fresh telemetry ({self.recovery_count}/{configuration.recovery_samples})",
                )
                return self.decision
            self.recovering = False
            self.detector.reset()

        mode = self.detector.update(sample)
        if mode is None:
            candidate = self.detector.candidate
            if candidate != "import":
                self.import_demand_ceiling_w = None
                self.import_activation_peak_w = 0
            state = (
                VoltageControlState.GRID_CHARGING
                if candidate == "import"
                else VoltageControlState.EXPORTING
                if candidate == "export"
                else VoltageControlState.STANDBY
            )
            reason = (
                "waiting for activation delay" if candidate else "no sustained controllable flow"
            )
            self.decision = ControlDecision(
                state,
                ControlAction.STANDBY,
                candidate,
                None,
                sample.raw_voltage_v,
                filtered,
                reason,
            )
            return self.decision

        if immediate_mode != mode:
            current_w = current_import_w if mode == "import" else current_export_w
            self.decision = self._hold(
                mode,
                current_w,
                sample,
                filtered,
                "operating condition ended; waiting for deactivation delay",
            )
            return self.decision

        if mode == "import":
            decision = self._evaluate_import(sample, filtered, current_import_w)
        else:
            self.import_demand_ceiling_w = None
            self.import_activation_peak_w = 0
            decision = self._evaluate_export(sample, filtered, current_export_w)
        self.decision = decision
        return decision

    def _evaluate_import(
        self, sample: GridTelemetrySample, filtered: float, current_w: int
    ) -> ControlDecision:
        c = self.configuration
        if self.import_demand_ceiling_w is None:
            self.import_demand_ceiling_w = max(
                c.minimum_import_w,
                min(
                    c.maximum_import_w,
                    self.import_activation_peak_w + c.import_headroom_w,
                ),
            )
        demand_ceiling_w = self.import_demand_ceiling_w
        if sample.raw_voltage_v <= c.minimum_voltage_v:
            desired = max(c.minimum_import_w, current_w - c.emergency_reduction_w)
            return ControlDecision(
                VoltageControlState.EMERGENCY_LOW_VOLTAGE,
                ControlAction.EMERGENCY,
                "import",
                desired,
                sample.raw_voltage_v,
                filtered,
                "raw PCC voltage reached the absolute minimum",
                True,
            )
        if filtered < c.import_target_v - c.deadband_v:
            reduction = (
                c.near_limit_reduction_w
                if sample.raw_voltage_v <= c.minimum_voltage_v + c.deadband_v
                else c.reduction_step_w
            )
            desired = max(c.minimum_import_w, current_w - reduction)
            return self._normal_decision(
                "import", desired, sample, filtered, ControlAction.REDUCING
            )
        if current_w > demand_ceiling_w:
            return ControlDecision(
                VoltageControlState.IMPORT_REGULATING,
                ControlAction.REDUCING,
                "import",
                demand_ceiling_w,
                sample.raw_voltage_v,
                filtered,
                f"trimming unused allowance to {c.import_headroom_w / 1_000:g} kW "
                "above measured import",
            )
        if filtered > c.import_target_v + c.deadband_v:
            if sample.age_s > c.fresh_age_s:
                return self._hold(
                    "import",
                    current_w,
                    sample,
                    filtered,
                    "telemetry is not fresh enough to increase",
                )
            if sample.monotonic_s < self.settle_until:
                return self._hold(
                    "import",
                    current_w,
                    sample,
                    filtered,
                    "waiting for the previous change to settle",
                )
            headroom = filtered - (c.import_target_v + c.deadband_v)
            desired = min(demand_ceiling_w, current_w + self._increase_step(headroom))
            if desired == current_w:
                return self._hold(
                    "import",
                    current_w,
                    sample,
                    filtered,
                    f"{c.import_headroom_w / 1_000:g} kW demand headroom reached",
                )
            return self._normal_decision(
                "import", desired, sample, filtered, ControlAction.INCREASING
            )
        return self._hold(
            "import", current_w, sample, filtered, "voltage is inside the import deadband"
        )

    def _evaluate_export(
        self, sample: GridTelemetrySample, filtered: float, current_w: int
    ) -> ControlDecision:
        c = self.configuration
        if sample.raw_voltage_v >= c.maximum_voltage_v:
            desired = max(0, current_w - c.emergency_reduction_w)
            return ControlDecision(
                VoltageControlState.EMERGENCY_HIGH_VOLTAGE,
                ControlAction.EMERGENCY,
                "export",
                desired,
                sample.raw_voltage_v,
                filtered,
                "raw PCC voltage reached the absolute maximum",
                True,
            )
        if filtered > c.export_target_v + c.deadband_v:
            reduction = (
                c.near_limit_reduction_w
                if sample.raw_voltage_v >= c.maximum_voltage_v - c.deadband_v
                else c.reduction_step_w
            )
            desired = max(0, current_w - reduction)
            return self._normal_decision(
                "export", desired, sample, filtered, ControlAction.REDUCING
            )
        if filtered < c.export_target_v - c.deadband_v:
            if sample.age_s > c.fresh_age_s:
                return self._hold(
                    "export",
                    current_w,
                    sample,
                    filtered,
                    "telemetry is not fresh enough to increase",
                )
            if sample.monotonic_s < self.settle_until:
                return self._hold(
                    "export",
                    current_w,
                    sample,
                    filtered,
                    "waiting for the previous change to settle",
                )
            headroom = (c.export_target_v - c.deadband_v) - filtered
            desired = min(
                c.effective_maximum_export_w,
                current_w + self._increase_step(headroom),
            )
            if desired == current_w:
                return self._hold(
                    "export", current_w, sample, filtered, "maximum permitted export reached"
                )
            return self._normal_decision(
                "export", desired, sample, filtered, ControlAction.INCREASING
            )
        return self._hold(
            "export", current_w, sample, filtered, "voltage is inside the export deadband"
        )

    @staticmethod
    def _state(mode: str) -> VoltageControlState:
        return (
            VoltageControlState.IMPORT_REGULATING
            if mode == "import"
            else VoltageControlState.EXPORT_REGULATING
        )

    def _normal_decision(
        self,
        mode: str,
        desired_w: int,
        sample: GridTelemetrySample,
        filtered: float,
        action: ControlAction,
    ) -> ControlDecision:
        return ControlDecision(
            self._state(mode),
            action,
            mode,
            desired_w,
            sample.raw_voltage_v,
            filtered,
            f"{action.value.lower()} {mode} allowance",
        )

    def _hold(
        self,
        mode: str,
        current_w: int,
        sample: GridTelemetrySample,
        filtered: float,
        reason: str,
    ) -> ControlDecision:
        return ControlDecision(
            self._state(mode),
            ControlAction.HOLDING,
            mode,
            current_w,
            sample.raw_voltage_v,
            filtered,
            reason,
        )


class ControllerJournal:
    """Small crash-recovery record; it contains configuration state, not telemetry."""

    def __init__(self, path: Path, device_identity: str | None = None):
        self.path = path
        self.device_identity = device_identity or str(path.resolve())
        self.lock_descriptor: int | None = None

    def acquire_lock(self) -> None:
        directory = Path(tempfile.gettempdir()) / f"solis-control-{os.getuid()}"
        directory.mkdir(mode=0o700, exist_ok=True)
        key = hashlib.sha256(self.device_identity.encode()).hexdigest()
        descriptor = os.open(directory / f"{key}.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(descriptor)
            raise RuntimeError("another controller already owns this inverter") from None
        self.lock_descriptor = descriptor

    def close(self) -> None:
        if self.lock_descriptor is not None:
            os.close(self.lock_descriptor)
            self.lock_descriptor = None

    def load(self) -> dict[str, Any] | None:
        try:
            value = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        if not isinstance(value, dict) or value.get("device_identity") != self.device_identity:
            raise ValueError("control journal identity is missing or does not match this inverter")
        return value

    def write(self, value: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            json.dump(value, destination, sort_keys=True)
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary, self.path)
        descriptor = os.open(self.path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def start(
        self,
        session_id: str,
        baseline_import_raw: int,
        baseline_export_raw: int,
        last_import_raw: int,
        last_export_raw: int,
        timestamp: str,
    ) -> dict[str, Any]:
        value: dict[str, Any] = {
            "device_identity": self.device_identity,
            "session_id": session_id,
            "clean_shutdown": False,
            "baseline_import_raw": baseline_import_raw,
            "baseline_export_raw": baseline_export_raw,
            "last_commanded_import_raw": last_import_raw,
            "last_commanded_export_raw": last_export_raw,
            "import_control_was_active": False,
            "export_control_was_active": False,
            "timestamp": timestamp,
        }
        self.write(value)
        return value

    def update_command(self, value: dict[str, Any], mode: str, raw: int, timestamp: str) -> None:
        value.pop(f"pending_{mode}_raw", None)
        value[f"last_commanded_{mode}_raw"] = raw
        value[f"{mode}_control_was_active"] = True
        value["timestamp"] = timestamp
        self.write(value)

    def prepare_command(self, value: dict[str, Any], mode: str, raw: int) -> None:
        value[f"pending_{mode}_raw"] = raw
        value["clean_shutdown"] = False
        self.write(value)

    def mark_clean(self, value: dict[str, Any], timestamp: str) -> None:
        value["clean_shutdown"] = True
        value["timestamp"] = timestamp
        self.write(value)


def configuration_dict(configuration: DynamicVoltageConfiguration) -> dict[str, Any]:
    return asdict(configuration)
