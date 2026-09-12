"""Kinematics engine for Garmin_Liftosaur (Phase 4).

Conventions (contract docs/02, section 4):
  * Acceleration in m/s^2; gravity ~ +9.81 on the vertical (Z) axis at rest.
  * The watch streams raw int16 fixed-point samples; accel_m_s2 = raw / scale.
  * Vertical motion lives on Z. We isolate gravity, low/high-pass filter,
    integrate acceleration -> velocity, and compute power as P = m*a*v.
  * Units: mass kg, velocity m/s, power watts, displacement m.

Acceptance (contract): peak_velocity roughly 0.5-2.5 m/s and peak_power
roughly 200-1500 W for a real set; absurd values (e.g. 10,000 W) mean the
filtering/integration is broken.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy import signal

# Vertical axis index into each [x, y, z] sample row.
_Z = 2
# Standard gravity, m/s^2.
_G = 9.80665

# Filter design
_LOWPASS_CUTOFF_HZ = 10.0      # attenuate sensor noise above ~10 Hz
_HIGHPASS_CUTOFF_HZ = 0.1      # remove residual low-frequency drift (DC is already
                               # removed by median subtraction; keep this well below
                               # the ~0.4 Hz squat cadence so we don't eat the signal)
_FILTER_ORDER = 4


@dataclass
class PhysicsResult:
    peak_velocity_m_s: float
    peak_power_w: float
    mean_power_w: float
    displacement_m: float
    duration_s: float
    warnings: list[str]


def effective_cutoff(desired_hz: float, rate: float) -> float:
    """Clamp a desired cutoff into (0, nyquist), with margin.

    A cutoff at or above Nyquist is unrepresentable and scipy raises. That is a
    real case here, not a theoretical one: Garmin's Toybox.Sensor delivers
    ~20 Hz on a Venu 2S, so Nyquist is 10 Hz -- exactly the nominal 10 Hz
    low-pass design. Without this clamp every ~20 Hz set from the watch is
    rejected with HTTP 422 before any physics runs.
    """
    if rate <= 0:
        raise ValueError("rate must be > 0")
    max_cut = 0.45 * rate  # keep a clear margin below Nyquist
    return max_cut if desired_hz >= max_cut else desired_hz


def _butter(order: int, cutoff: float, rate: float, kind: str):
    """Design a zero-phase Butterworth filter, guarding against nyquist issues."""
    nyq = 0.5 * rate
    if cutoff <= 0 or cutoff >= nyq:
        raise ValueError(f"cutoff {cutoff} Hz must be in (0, {nyq:.1f}) Hz at rate {rate} Hz")
    b, a = signal.butter(order, cutoff / nyq, btype=kind)
    return b, a


def _filtfilt(x: np.ndarray, rate: float, lowpass: bool = True) -> np.ndarray:
    """Apply a zero-phase (filtfilt) Butterworth filter to a 1-D signal.

    The requested cutoff is clamped against Nyquist first (see
    `effective_cutoff`), so low sample rates degrade the filter bandwidth
    instead of failing the whole request.
    """
    order = _FILTER_ORDER
    desired = _LOWPASS_CUTOFF_HZ if lowpass else _HIGHPASS_CUTOFF_HZ
    cutoff = effective_cutoff(desired, rate)
    kind = "low" if lowpass else "high"
    b, a = _butter(order, cutoff, rate, kind)
    padlen = 3 * (2 * order + 1)  # enough edge padding for filtfilt
    if len(x) <= padlen:
        return x.copy()
    return signal.filtfilt(b, a, x, padlen=padlen)


def _remove_gravity(z: np.ndarray) -> np.ndarray:
    """Isolate the dynamic (non-gravitational) vertical acceleration.

    We subtract the median of the whole signal (robust to sensor spikes). For a
    wrist resting before/after the set this is ~9.81 m/s^2, so the residual is
    the bar's own vertical acceleration with zero-mean bias removed.
    """
    baseline = float(np.median(z))
    return z - baseline


def compute_physics(
    raw_samples: list[list[int]] | np.ndarray,
    scale: int,
    sample_rate_hz: int,
    mass_kg: float,
    duration_s: float | None = None,
) -> PhysicsResult:
    """Derive velocity, power and displacement from raw fixed-point samples.

    raw_samples:  (N, 3) array of int16 [x, y, z] fixed-point rows.
    scale:        divisor converting raw -> m/s^2 (per contract 02).
    sample_rate_hz: ground-truth rate from the watch.
    mass_kg:      total lifted mass (bar + plates), kg.
    duration_s:   observed wall-clock duration; defaults to N / rate.
    """
    warnings: list[str] = []
    arr = np.asarray(raw_samples, dtype=np.float64)
    if arr.ndim != 2 or arr.shape[1] < 3:
        raise ValueError("raw_samples must be an (N,3) array of [x,y,z] rows")
    if scale <= 0:
        raise ValueError("scale must be > 0")
    if sample_rate_hz <= 0:
        raise ValueError("sample_rate_hz must be > 0")
    if mass_kg <= 0:
        raise ValueError("mass_kg must be > 0")

    n = arr.shape[0]
    if n < 4:
        warnings.append("too_few_samples")
        return PhysicsResult(0.0, 0.0, 0.0, 0.0, float(duration_s or 0.0), warnings)

    # 1. Convert fixed-point -> m/s^2.
    accel = arr / float(scale)

    # 2. Low-pass filter the vertical axis to denoise before differentiation.
    z_raw = accel[:, _Z]
    z_lp = _filtfilt(z_raw, sample_rate_hz, lowpass=True)

    # 3. Isolate the dynamic acceleration (remove gravity / DC bias).
    a_dyn = _remove_gravity(z_lp)

    # 4. High-pass the dynamic acceleration to kill residual drift, then integrate.
    a_filt = _filtfilt(a_dyn, sample_rate_hz, lowpass=False)
    dt = 1.0 / sample_rate_hz
    velocity = np.cumsum(a_filt) * dt  # m/s

    # 5. Detrend velocity: a full set starts & ends near rest, so remove the
    #    linear trend (this corrects integration drift / sensor bias).
    velocity = signal.detrend(velocity)

    # 6. Displacement = integral of velocity (m).
    displacement = np.cumsum(velocity) * dt

    duration = float(duration_s) if duration_s is not None else n / sample_rate_hz

    # 7. Power P = m * a * v (instantaneous mechanical power, watts).
    power = mass_kg * a_filt * velocity

    peak_v = float(np.max(np.abs(velocity)))
    peak_p = float(np.max(power))
    mean_p = float(np.mean(power))

    # Physical sanity / acceptance checks (contract 02 section 4).
    if not (0.5 <= peak_v <= 2.5):
        warnings.append("peak_velocity_out_of_expected_range")
    if not (200.0 <= peak_p <= 1500.0):
        warnings.append("peak_power_out_of_expected_range")

    return PhysicsResult(
        peak_velocity_m_s=peak_v,
        peak_power_w=peak_p,
        mean_power_w=mean_p,
        displacement_m=float(displacement[-1] - displacement[0]),
        duration_s=duration,
        warnings=warnings,
    )
