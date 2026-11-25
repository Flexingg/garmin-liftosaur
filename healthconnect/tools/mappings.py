"""Health Connect <-> FIT enum mappings.

Health Connect constants were read from developer.android.com
(androidx.health.connect.client.records.ExerciseSessionRecord / ExerciseSegment);
FIT enums from the Garmin FIT SDK profile 21.x (garmin-fit-sdk Profile). See
../FINDINGS.md for provenance.
"""

# key -> FIT sport/sub_sport + the sport-profile name a Venu 2S writes in mesg 12/session.110
# "moving": has distance/route/cadence (walk-like template); otherwise strength-like.
SPORTS = {
    "walking":     {"sport": 11, "sub_sport": 0,  "name": "Walk",       "moving": True},
    "running":     {"sport": 1,  "sub_sport": 0,  "name": "Run",        "moving": True},
    "treadmill":   {"sport": 1,  "sub_sport": 1,  "name": "Treadmill",  "moving": True},
    "hiking":      {"sport": 17, "sub_sport": 0,  "name": "Hike",       "moving": True},
    "cycling":     {"sport": 2,  "sub_sport": 0,  "name": "Bike",       "moving": True},
    "strength":    {"sport": 10, "sub_sport": 20, "name": "Strength",   "moving": False},
    "cardio":      {"sport": 10, "sub_sport": 26, "name": "Cardio",     "moving": False},
    "hiit":        {"sport": 10, "sub_sport": 70, "name": "HIIT",       "moving": False},
    "yoga":        {"sport": 10, "sub_sport": 43, "name": "Yoga",       "moving": False},
    "pilates":     {"sport": 10, "sub_sport": 44, "name": "Pilates",    "moving": False},
    "elliptical":  {"sport": 4,  "sub_sport": 15, "name": "Elliptical", "moving": False},
    "indoor_bike": {"sport": 2,  "sub_sport": 6,  "name": "Bike Indoor", "moving": False},
    "indoor_row":  {"sport": 15, "sub_sport": 14, "name": "Row Indoor", "moving": False},
    "stair":       {"sport": 4,  "sub_sport": 16, "name": "Stair Stepper", "moving": False},
}

# ExerciseSessionRecord.EXERCISE_TYPE_* -> SPORTS key
HC_EXERCISE_TYPE = {
    79: "walking", 56: "running", 57: "treadmill", 37: "hiking", 8: "cycling", 9: "indoor_bike",
    70: "strength", 81: "strength", 13: "strength", 36: "hiit", 83: "yoga", 48: "pilates",
    25: "elliptical", 54: "indoor_row", 68: "stair", 69: "stair", 10: "cardio", 26: "cardio", 0: "cardio",
}

# FIT exercise_category (subset of profile type exercise_category)
FIT_CATEGORY = {
    "bench_press": 0, "calf_raise": 1, "cardio": 2, "carry": 3, "chop": 4, "core": 5, "crunch": 6,
    "curl": 7, "deadlift": 8, "flye": 9, "hip_raise": 10, "hip_stability": 11, "hip_swing": 12,
    "hyperextension": 13, "lateral_raise": 14, "leg_curl": 15, "leg_raise": 16, "lunge": 17,
    "olympic_lift": 18, "plank": 19, "plyo": 20, "pull_up": 21, "push_up": 22, "row": 23,
    "shoulder_press": 24, "shoulder_stability": 25, "shrug": 26, "sit_up": 27, "squat": 28,
    "total_body": 29, "triceps_extension": 30, "warm_up": 31, "run": 32, "unknown": 65534,
}

# ExerciseSegment.EXERCISE_SEGMENT_TYPE_* -> FIT exercise_category name
HC_SEGMENT_TO_FIT = {
    1: "curl", 2: "hyperextension", 3: "total_body", 4: "shoulder_press", 5: "bench_press",
    6: "sit_up", 9: "total_body", 10: "crunch", 11: "deadlift", 12: "triceps_extension",
    13: "curl", 14: "curl", 15: "lateral_raise", 16: "lateral_raise", 17: "row",
    18: "triceps_extension", 19: "triceps_extension", 20: "triceps_extension", 22: "core",
    23: "lateral_raise", 25: "hip_raise", 27: "cardio", 28: "cardio", 29: "hip_swing",
    30: "lateral_raise", 31: "pull_up", 32: "leg_curl", 33: "unknown", 34: "squat",
    35: "leg_raise", 36: "lunge", 37: "cardio", 41: "plank", 42: "pull_up", 48: "shoulder_press",
    49: "triceps_extension", 50: "sit_up", 51: "squat", 63: "core", 65: "olympic_lift",
}
HC_SEGMENT_REST = {39, 44}  # PAUSE, REST

# a few Liftosaur names -> FIT category (extend as needed)
LIFTOSAUR_TO_FIT = {
    "bench press": "bench_press", "squat": "squat", "deadlift": "deadlift",
    "overhead press": "shoulder_press", "shoulder press": "shoulder_press", "bicep curl": "curl",
    "chin up": "pull_up", "pull up": "pull_up", "lat pulldown": "pull_up", "bent over row": "row",
    "upright row": "row", "plank": "plank", "push up": "push_up", "triceps extension": "triceps_extension",
    "lunge": "lunge", "leg press": "squat", "lateral raise": "lateral_raise", "shrug": "shrug",
    "romanian deadlift": "deadlift", "hip thrust": "hip_raise", "leg curl": "leg_curl",
}


def exercise_to_fit(ex):
    """Return (category, subtype) for an HC segment int, FIT name, or Liftosaur name."""
    if ex is None:
        return FIT_CATEGORY["unknown"], None
    if isinstance(ex, int):
        return FIT_CATEGORY[HC_SEGMENT_TO_FIT.get(ex, "unknown")], None
    s = str(ex).strip().lower()
    if s.isdigit():
        return exercise_to_fit(int(s))
    if s in FIT_CATEGORY:
        return FIT_CATEGORY[s], None
    base = s.split(",")[0].strip()
    for k, v in LIFTOSAUR_TO_FIT.items():
        if k in base:
            return FIT_CATEGORY[v], None
    return FIT_CATEGORY["unknown"], None
