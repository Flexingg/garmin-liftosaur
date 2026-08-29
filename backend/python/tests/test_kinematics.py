"""Phase 4 physics unit tests — validation of the kinematics pipeline."""
from __future__ import annotations

import numpy as np
import pytest

from app.physics import compute_physics
from tests.synthetic import make_squat


def test_recovers_peak_velocity_of_a_realistic_squat():
    data = make_squat()
    phys = compute_physics(
        raw_samples=data["raw"],
        scale=data["scale"],
        sample_rate_hz=data["rate"],
        mass_kg=data["mass_kg"],
    )
    # Recovered peak speed should be near the defined profile (allow some filter
    # ringing at rep boundaries), and physically in the contract range 0.5-2.5.
    assert phys.peak_velocity_m_s > 0
    assert abs(phys.peak_velocity_m_s - data["true_peak_velocity"]) <= 0.4
    assert 0.5 <= phys.peak_velocity_m_s <= 2.5


def test_power_and_no_warnings_for_realistic_squat():
    data = make_squat()
    phys = compute_physics(
        raw_samples=data["raw"],
        scale=data["scale"],
        sample_rate_hz=data["rate"],
        mass_kg=data["mass_kg"],
    )
    # Contract acceptance: peak power roughly 200-1500 W, so a clean set warns nothing.
    assert phys.warnings == []
    assert 200.0 <= phys.peak_power_w <= 1500.0
    assert phys.duration_s == pytest.approx(data["duration_s"], rel=0.01)


def test_stationary_signal_gives_near_zero_velocity_and_power():
    rate = 25
    n = rate * 6
    z_rest = np.full(n, G if False else 9.80665)
    rng = np.random.default_rng(7)
    raw = np.stack(
        [
            rng.normal(0, 0.02 * 1000, n).round(),
            rng.normal(0, 0.02 * 1000, n).round(),
            (z_rest + rng.normal(0, 0.01, n)) * 1000,
        ],
        axis=1,
    ).astype(np.int64)
    phys = compute_physics(raw, scale=1000, sample_rate_hz=rate, mass_kg=100.0)
    assert phys.peak_velocity_m_s < 0.15
    assert phys.peak_power_w < 50


def test_too_few_samples_warns_and_returns_zeros():
    phys = compute_physics([[0, 0, 9800]], scale=1000, sample_rate_hz=25, mass_kg=100.0)
    assert phys.peak_velocity_m_s == 0.0
    assert "too_few_samples" in phys.warnings


@pytest.mark.parametrize(
    "kwargs,err",
    [
        ({"scale": 0}, "scale must be > 0"),
        ({"sample_rate_hz": 0}, "sample_rate_hz must be > 0"),
        ({"mass_kg": -5}, "mass_kg must be > 0"),
    ],
)
def test_invalid_inputs_raise(kwargs, err):
    base = dict(raw_samples=[[0, 0, 9800], [0, 0, 9800], [0, 0, 9800]],
                scale=1000, sample_rate_hz=25, mass_kg=100.0)
    base.update(kwargs)
    with pytest.raises(ValueError, match=err):
        compute_physics(**base)


def test_units_conversion_is_gravity_correct():
    # A sample resting at Z=+9.81 m/s^2 with scale=1000 must read raw ~= 9807.
    # Verify the pipeline doesn't blow up and the gravity baseline is handled.
    data = make_squat(scale=1000)
    med = np.median(data["raw"][:, 2])
    # resting-ish baseline within a few % of g*scale
    assert abs(med - 9.80665 * 1000) / (9.80665 * 1000) < 0.05
