# healthconnect — Wear OS / Health Connect → Garmin Connect (as your Venu 2S)

Turn workouts recorded on a Wear OS watch (anything that lands in Android Health
Connect) into FIT activities that Garmin Connect treats as recorded on **your own
Venu 2S**. Stdlib-only Python. `garminconnect` is needed only for scripted upload.

**Verdict: doable.** FIT files are not signed (just a CRC). Device identity is plain
data, so we clone it from a real file your watch wrote. Everything else is generated
in the watch's exact message layout. Details are in **[FINDINGS.md](FINDINGS.md)**.

```
Wear OS app ─▶ Health Connect ─▶ "Health Connect.zip" ─▶ hc_export_reader.py ─▶ session.json
                                                                                     │
          real Venu 2S FIT (template: identity + layouts) ──────────▶ build_fit.py ◀─┘
                                                                         │
                                                       .fit ─▶ upload.py / connect.garmin.com/modern/import-data
```

## Quick start

```bash
cd healthconnect
mkdir templates   # git-ignored
# 1. Garmin Connect (web) > one walk + one strength activity > gear > Export Original > unzip into templates/
# 2. Phone: Settings > Health Connect > Export data  ->  "Health Connect.zip"
python3 tools/hc_export_reader.py "Health Connect.zip" --schema   # sanity check (send me this if anything fails)
python3 tools/hc_export_reader.py "Health Connect.zip" --list
python3 tools/port.py "Health Connect.zip" --templates templates --since 2026-11-01 --out out
python3 tools/fit_fingerprint.py --diff templates/<real walk>.fit out/<generated walk>.fit   # optional
# 3. Upload: drag out/*.fit into https://connect.garmin.com/modern/import-data, or
pip install --upgrade garminconnect curl_cffi
python3 tools/upload.py out/*.fit --dry-run   # checks for overlapping activities first
python3 tools/upload.py out/*.fit
```

Start with **one** file and check it in Garmin Connect before doing a batch: device
name, HR graph, Training Effect, sets.

## Tools

| file | what |
|---|---|
| `tools/fitlib.py` | tiny FIT reader/writer (no deps). Handles undocumented fields and fixed layouts |
| `tools/build_fit.py` | session JSON + template FIT → Venu-2S-shaped FIT |
| `tools/hc_export_reader.py` | Health Connect export → session JSON. AOSP table names; skips Garmin-originated data |
| `tools/port.py` | the whole pipeline in one command |
| `tools/upload.py` | Garmin Connect upload via python-garminconnect, with duplicate/overlap check |
| `tools/fit_fingerprint.py` | structural fingerprint / diff of FIT files |
| `tools/fit_to_session.py` | real FIT → session JSON (round-trip testing) |
| `tools/mappings.py` | Health Connect exercise/segment types ↔ FIT sport/exercise_category |
| `samples/session.example.json` | the normalized session format (synthetic data) |

Session JSON for strength can carry `weight_kg` per set. Health Connect has no such
field, so the plan is to merge Liftosaur history by time, which this repo already
talks to (see "Next").

## Privacy

This repo is **public**. `healthconnect/.gitignore` blocks `templates/`, `out/`,
`*.fit`, `*.zip` and `*.db`. Your FITs carry GPS, weight/height, resting HR and the
watch's Unit ID. Credentials come from the environment or a prompt, and tokens are
cached in `~/.garminconnect`.

## Caveats

- Uploading data as your own device to your own account is the same thing
  Fit-File-Faker does. It is still outside what Garmin intends, so use it on your own
  data only.
- If the watch was also recording at the same time, don't import that Wear OS
  session. You'd double-count the day. `upload.py` skips overlaps unless `--force`.
- Body Battery, stress and daily steps won't change. Those come from watch wellness
  files, not activities.
- Training Effect/Status is expected to work but not yet confirmed. See FINDINGS §5.

## Next (needs your input)

1. **A real Health Connect export** with a few Wear OS workouts in it, ideally one walk
   and one strength session. The schema is from AOSP source but has not been checked
   against a real export yet. Running `--schema` and `--list` on it is enough; the raw
   file doesn't need to be shared.
2. **Which watch and app record the workouts** (Pixel Watch/Fitbit, Samsung Health,
   Health Services app...). That decides whether HR is 1 Hz, whether routes and
   segments/reps exist, and the package name to filter on.
3. **One live upload test** of a generated file, to confirm the device attribution and
   Training Effect behaviour on the server.
4. Whether strength weights should be merged in from **Liftosaur history**, matching
   sets by time.
