"""Shared synthetic squat generator for backend tests.

Builds a physically-consistent raw fixed-point accelerometer stream for a
barbell squat: we define a realistic bar-velocity profile, differentiate to get
dynamic vertical acceleration, add gravity (Z ~ +9.81 m/s^2), add noise, and
quantize to int16 with a given scale. Tests the whole Phase 4 pipeline against
a known ground truth.
"""
from __future__ import annotations

import numpy as np

G = 9.80665


def make_squat(
    rate: int = 25,
    n_reps: int = 5,
    rep_dur: float = 2.6,
    vmax: float = 1.4,
    ecc_frac: float = 0.9,  # down-phase peak velocity as a fraction of up-phase
    scale: int = 1000,
    noise_std: float = 0.08,  # m/s^2, applied to Z
    seed: int = 0,
    mass_kg: float = 102.3,
) -> dict:
    """Return a dict of ground-truth and the quantized raw samples."""
    half = rep_dur / 2.0
    n = int(round(n_reps * rep_dur * rate))
    t = np.arange(n) / rate
    v = np.zeros(n)

    def bump(x: np.ndarray, dur: float, peak: float) -> np.ndarray:
        return peak * 0.5 * (1.0 - np.cos(2 * np.pi * x / dur))

    for r in range(n_reps):
        t0 = r * rep_dur
        i0 = int(round(t0 * rate))
        i1 = int(round((t0 + half) * rate))
        v[i0:i1] = bump(t[i0:i1] - t0, half, vmax)
        i2 = int(round((t0 + half) * rate))
        i3 = int(round((t0 + rep_dur) * rate))
        v[i2:i3] = -bump(t[i2:i3] - (t0 + half), half, vmax * ecc_frac)

    a_dyn = np.gradient(v, t)  # dynamic vertical acceleration, m/s^2
    z_acc = G + a_dyn  # measured Z includes gravity

    rng = np.random.default_rng(seed)
    noise = rng.normal(0, noise_std, n)
    z = (z_acc + noise) * scale
    x = rng.normal(0, 0.05 * scale, n)
    y = rng.normal(0, 0.05 * scale, n)
    raw = np.stack([x.round(), y.round(), z.round()], axis=1).astype(np.int64)

    return {
        "rate": rate,
        "scale": scale,
        "raw": raw,
        "mass_kg": mass_kg,
        "true_peak_velocity": float(vmax),
        "duration_s": float(n / rate),
    }
