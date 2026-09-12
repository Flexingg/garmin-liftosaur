# 03 — Garmin Connect IQ toolchain, signing, and sideloading (verified)

**Status:** every command in this document was actually run and its output
observed on 2026-09-12, against a physical **Venu 2S** on Ubuntu 26.04 with
Connect IQ **SDK 9.2.0**. Where something is a guess it is marked *unverified*.

This is the reference for (a) updating this app and (b) starting a **new**
Garmin app from scratch. Read §4 and §7 before you debug anything — they
contain the two traps that cost the most time.

---

## 1. Quick start

```bash
cd embedded/monkeyc
./tools/linux-build.sh venu2s          # builds bin/Liftosaur.prg (enforces the key rules)
# then copy bin/Liftosaur.prg into GARMIN/APPS over MTP and PHYSICALLY UNPLUG the watch
```

---

## 2. Hardware facts

| Thing | Value |
|---|---|
| Watch | Garmin **Venu 2S** |
| Part number | `006-B3704-00` |
| SDK device id | `venu2s` |
| Firmware | `19.05` |
| CIQ device group | API level 5.0 (`connectIQVersion 5.0.0`) |
| USB mode needed | **MTP** (Settings → System → USB Mode) — *not* "Garmin" mode |
| USB id | `091e:4e78` (MTP) — `091e:0003` means you are in Garmin mode, wrong |

**Part number → SDK device id.** These are *not* interchangeable, and a
wrong-device build fails with a misleading signature error, not a clear one:

| Part number | SDK id |
|---|---|
| `006-B3704-00` | `venu2s` |
| `006-B3703-00` | `venu2` |

Always confirm against the device itself before building:

```bash
gio cat "mtp://<id>/Internal%20Storage/GARMIN/GarminDevice.xml" > /tmp/dev.xml
grep -o -E '<(PartNumber|SoftwareVersion|Description)>[^<]*' /tmp/dev.xml | head -3
# -> 006-B3704-00 / 1905 / Venu 2S
```

---

## 3. Toolchain install (Ubuntu 26.04)

```bash
sudo apt-get install -y openjdk-21-jdk-headless unzip curl openssl
```

The Connect IQ SDK ships **without per-device metadata**, so `monkeyc -d venu2s`
fails with `Invalid device id specified` until you pull device files. Garmin's
own SDK Manager GUI needs `libwebkit2gtk-4.0.so.37` (gone in Ubuntu ≥ 24.04), so
use lindell's headless CLI:

```bash
curl -sL -o /tmp/ciq.tgz \
  https://github.com/lindell/connect-iq-sdk-manager-cli/releases/download/v0.8.4/connect-iq-sdk-manager-cli_0.8.4_Linux_x86_64.tar.gz
tar -xzf /tmp/ciq.tgz -C ~/.local/bin

export GARMIN_USERNAME=... GARMIN_PASSWORD=...      # device downloads need a login
connect-iq-sdk-manager agreement accept
connect-iq-sdk-manager sdk set 9.2.0
connect-iq-sdk-manager device download --manifest=embedded/monkeyc/manifest.xml -F
```

Result lands in `~/.Garmin/ConnectIQ/Sdks/connectiq-sdk-lin-9.2.0-<hash>/` and
device metadata in `~/.Garmin/ConnectIQ/Devices/<deviceid>/`.

> **`$HOME` trap.** `tools/linux-build.sh` deliberately does *not* trust `$HOME`
> alone. Under an agent/tool harness `$HOME` can point at a profile directory,
> and the SDK lookup then fails with a confusing "SDK not found" even though the
> SDK is installed. The script probes several roots; if you write your own
> scripts, do the same.

---

## 4. Signing keys — **RSA 4096 is mandatory** (this is the big one)

### The finding

A **2048-bit** key compiles perfectly and produces a **cryptographically valid**
signature — and the watch still rejects it at install time with:

```
Error: 'Signature check failed on file: Liftosaur'
```

The **same source, same SDK, same target device**, rebuilt with a freshly
generated **4096-bit** key, installs and runs.

This was proven with a controlled experiment — four builds, one unplug:
`LiftA` (2048-bit key, control), `LiftB` (2048 + `-r`), `LiftC` (2048 +
`--disable-v2-opcodes`), `LiftD` (**fresh 4096-bit key**). The watch's log
rejected A, B and C and accepted **D**.

**Consequences for anything you write here:**

- The `keytool`-generated 2048-bit key that `embedded/monkeyc/README.md`
  originally recommended was the root cause of "the app never launches". That
  key is archived as `developer_key.2048-rejected.der` for reference — do not use it.
- **Registering the key with Garmin is NOT required for sideloading.** Both the
  rejected and the accepted keys were local throwaways. (An earlier internal note
  claimed otherwise; it is wrong.)
- `tools/linux-build.sh` now **refuses** any key under 4096 bits, so this cannot
  silently regress.

### Generating the key

```bash
cd embedded/monkeyc
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out developer_key.pem
openssl pkcs8 -topk8 -nocrypt -in developer_key.pem -outform DER -out developer_key.der
```

- monkeyc needs a **PKCS#8 DER private key**. A `.p12` PKCS12 keystore is
  rejected with `Unable to load private key: ... unknown version: 3`; export it
  first (`openssl pkcs12 -in k.p12 -nocerts -nodes -passin pass:<pw> -out k.pem`
  then the `pkcs8` line above).
- **Back the key up and never lose it.** The same key is required to update the
  app later, and the Connect IQ store ties uploaded apps to it. Keys are
  `gitignore`d (`embedded/monkeyc/developer_key.*`) — they are deliberately not
  in this repo.

Sanity check any key before blaming anything else:

```bash
openssl pkey -in developer_key.der -inform DER -text -noout | head -1
# must say: Private-Key: (4096 bit, 2 primes)
```

---

## 5. Build

```bash
cd embedded/monkeyc
./tools/linux-build.sh venu2s              # or: venu2, or extra monkeyc flags after the device
# raw equivalent:
monkeyc -d venu2s -f monkey.jungle -o bin/Liftosaur.prg -y developer_key.der -w
```

`BUILD SUCCESSFUL` plus a non-empty `.prg` is the success signal. `file` reports
`data` for `.prg` — that is normal (proprietary format).

**Confirm the artifact targets the right device** — cheapest possible pre-flight:

```bash
strings -a bin/Liftosaur.prg | grep -o -E '006-B[0-9]{4}-00' | sort -u
# -> 006-B3704-00     (i.e. venu2s; a stripped -r build has no such string)
```

Benign warnings you can ignore at this project's `typecheck=1`:
`Cannot determine if container access is using container type` and
`Statement is not reachable`.

**The launcher icon warning is NOT benign.** The Device Reference for venu2s lists
**Launcher Icon Size: 61 × 61**. Shipping a 16 × 16 asset compiles fine but the
watch falls back to its placeholder glyph in the app list instead of showing the
app icon. `resources/images/icon.png` is now authored at 61 × 61 and the warning
is gone — treat any future launcher-icon notice as a real defect, not noise.

### Build flags that matter

| Flag | Effect |
|---|---|
| `-d <device>` | **Always pass this.** Building without a target device produces a PRG carrying newer-SDK optimizations the device may not accept. |
| `-r` | Release: strips debug info (102 kB → 15 kB here). Signature-check-neutral in our test, but it is what VS Code ships and is the right thing for a real release. |
| `-w` | Show warnings. |
| `--disable-v2-opcodes` | Opcode-format fallback. Tested here and it did **not** fix the rejection — do not reach for it first. |
| `-y <key>` | Signing key. |

---

## 6. Sideloading to the watch over USB

1. Watch → **Settings → System → USB Mode → MTP**. Plug in a **data-capable**
   cable (a charge-only cable powers the watch but never enumerates — if
   `lsusb | grep -i garmin` is empty, swap the cable first).
2. Mount and copy:

```bash
export HOME=/home/hermes XDG_RUNTIME_DIR=/run/user/1000 \
       DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
gio mount -l | grep -i mtp                      # find the mtp:// URI
U="mtp://<id>/Internal%20Storage/GARMIN/APPS"   # note: %20 for the space
gio copy -p bin/Liftosaur.prg "$U/Liftosaur.prg"
gio list "$U"                                   # confirm it landed
```

- Use `gio copy`, **not** `cp`. `cp`/`touch` fail with `Operation not supported`
  because they do not speak gvfs/MTP — that is *not* a read-only folder.
- The `.prg` **stays in `APPS` until the cable is physically unplugged**. A
  software eject (`gio mount -u`) does **not** install it. If it is still listed
  on a remount, the watch has not ingested it yet.
3. **Physically unplug the cable** — this is when the watch runs the signature
   check, installs, and moves the `.prg` into hidden storage (so it disappearing
   from `APPS` is normal and expected).
4. On the watch, press **START / the top-right button** to open the combined
   activity **and app list**, and look for **Liftosaur**.

**App identity is the manifest UUID.** The device keys an installed app by
`<iq:application id="...">`. Rebuilding with the *same* UUID updates that app in
place; a *different* UUID installs a second app alongside it. The current
`manifest.xml` UUID is the one installed on the watch — keep it stable unless you
deliberately want a second app.

---

## 7. Diagnosing "Signature check failed on file: X"

The error text is identical for several unrelated causes, so **check in this
order** and do not assume it is about the key:

| # | Cause | How to confirm | Fix |
|---|---|---|---|
| 1 | PRG built for the **wrong device** | `strings bin/*.prg \| grep '006-B'` vs `<PartNumber>` in `GarminDevice.xml` | Build with the right `-d`; add the `<iq:product>` to the manifest |
| 2 | **SDK too old** for the firmware | Garmin's rule: sideloads on System 8 / CIQ 5.1+ need SDK **≥ 7.4.3** | Update the SDK |
| 3 | **Signing key under 4096 bit** | `openssl pkey -in developer_key.der -inform DER -text -noout \| head -1` | Regenerate 4096-bit (§4) — *this was our actual bug* |

Also possible, not yet encountered here: a PRG carrying newer-SDK optimizations
the device firmware cannot parse (Garmin staff: *"If building without a target
device then it'll include the optimizations, which will cause the error you were
seeing on older devices"*) — mitigated by always passing `-d`.

Where the evidence lives:

- `GARMIN/APPS/LOGS/CIQ_LOG.YML` — written per launch attempt/failure. Read it
  first; it names the file it rejected.
- `CIQ_LOG.BAK` — the *previous* log. Check the `Appname:` field: it is often a
  stock Garmin app (*"Challenges"*, *"Leaderboard"*) and nothing to do with you.
- `GARMIN/APPS/DATA/*` and `APPS/SETTINGS/*.SET` gain entries for installed CIQ
  apps. **No entry = the app never registered.**

### Proving a `.prg` is genuinely signed (no hardware needed)

When the error looks like a signature problem, verify the signature off-device
before touching the key. This is how the 2048/4096 distinction was isolated:

```bash
# 1. Garmin's own PRG parser will tell you the section layout. Extract the class:
SDK=~/.Garmin/ConnectIQ/Sdks/connectiq-sdk-lin-9.2.0-*
mkdir -p /tmp/mb && cd /tmp/mb
unzip -o -q "$SDK/bin/monkeybrains.jar" 'com/garmin/connectiq/common/prgreader/*'
# (then a ~20-line Java driver calling new PrgReader(new DataInputStream(...)).parse(t)
#  and getSectionOffset(t) for each PrgReader$PrgSectionType)
# -> DEVELOPER_SIGNATURE offset, e.g. 0x189b8
```

```python
# 2. Layout of the DEVELOPER_SIGNATURE section:
#    [8-byte header][256/512-byte signature][pubkey: 00|modulus|exponent][2nd signature]
# 3. Verify it with the public half of your signing key:
#    openssl pkey -in developer_key.der -inform DER -pubout -out /tmp/k.pem
#    openssl dgst -sha1   -verify /tmp/k.pem -signature sig.bin payload.bin
#    openssl dgst -sha256 -verify /tmp/k.pem -signature sig2.bin payload.bin
```

Our rejected 2048-bit build verified cleanly as **SHA-1 and SHA-256** over
`payload = prg[0:signature_section_offset]`. So a valid signature is *not*
sufficient — the device additionally enforces key strength. Do not conclude
"the file is fine, it must be the watch" from a successful verification alone.

Two self-inflicted traps worth knowing, both of which produced a *false negative*
while doing this analysis: searching a PRG for a key by pasting a modulus hex
blob that accidentally includes the exponent (`0203010001`) or drops the DER
`00` INTEGER prefix will report "key not present" even when it is. Extract the
modulus from the key with `openssl ... -modulus` and search for that.

---

## 8. What is NOT a route to the watch

- `monkeydo` — **simulator only**: *"The simulator must be running for this
  command to succeed."* It pushes to the simulator's virtual device, not the watch.
- `mdd` (MonkeyDoDo) — a debug **attach** tool (`-d/--device`, `-e/--executable`,
  `-x/--debug-xml`), not a "run on watch" command.
- There is no Linux CLI equivalent of the phone's debug-app launch. Installing to
  hardware = MTP copy + unplug, or the phone Bluetooth debug-app flow.

## 9. Simulator

On Ubuntu ≥ 24.04 the native `bin/simulator` needs `libwebkit2gtk-4.0.so.37`,
`libsoup-2.4.so.1`, `libjavascriptcoregtk-4.0.so.18`, which are no longer shipped.
Installing old webkit debs onto 26.04 is fragile. Known workaround: extract the
self-contained simulator AppImage and point the native simulator at its libs:

```bash
curl -sL -o /tmp/Sim.AppImage https://github.com/pcolby/connectiq-sdk-manager/releases/download/v0.6.10/Connect_IQ_Simulator-9.2.0%2B162-x86_64.AppImage
chmod +x /tmp/Sim.AppImage && /tmp/Sim.AppImage --appimage-extract    # -> /tmp/squashfs-root
LD_LIBRARY_PATH=/tmp/squashfs-root/usr/lib <SDK>/bin/simulator &
```

Caveats we hit: the simulator window is a custom wxWidgets surface that desktop
screenshot/automation tooling (grim, gnome-screenshot, cua-driver) **cannot
capture**; and a pushed app could register in `~/.Garmin/ConnectIQ/simulator.ini`
yet never render (only the boot triangle). Verify simulator state via
`simulator.ini` / `strace`, not screenshots. For our purposes **the physical
watch over MTP is the reliable loop** — prefer it.

---

## 10. Starting a NEW Garmin app — checklist

1. **Identify the target device** by part number from the watch (§2) and map it
   to an SDK device id. Never guess; `venu2` vs `venu2s` is a real failure mode.
2. **`manifest.xml`**
   - `id` — a real random UUID; keep it stable for the life of the app
     (`python3 -c "import uuid;print(str(uuid.uuid4()).upper())"`).
   - `name` must be a **string resource** (`@Strings.AppName`), not a literal, or
     the build fails with *"A string resource matching the provided app name
     can't be found"*.
   - List every `<iq:product id="..."/>` you care about. (Note: listing several
     products does **not** change the artifact when you build with `-d` — verified
     byte-identical — so listing extra devices is harmless.)
   - Declare the permissions you use (`<iq:uses-permission id="Sensor"/>`,
     `Fit`, `Communications`, ...).
3. **`resources/strings.xml`** with the `AppName` id, and a launcher icon bitmap
   at the device's expected size (61×61 for the Venu 2S) to avoid scaling blur.
4. **`monkey.jungle`** — `project.manifest`, `typecheck`, `optimization`,
   `sourcePath`, `resourcePath`.
5. **Generate a 4096-bit key** (§4) and add `developer_key.*` to `.gitignore`.
6. **Copy `tools/linux-build.sh`** — it already handles the `$HOME` trap, the
   key-size enforcement, the device-target assertion, and prints sideload steps.
7. Build, check the `006-B...` target string, sideload, **unplug**, then find the
   app via START on the watch.
8. If it does not appear, read `GARMIN/APPS/LOGS/CIQ_LOG.YML` and work §7 in order.

### Publishing later (store)

- Store uploads enforce a **minimum SDK** (≥ 8.1 as of Garmin's 2025 notice; it
  rises over time) — keep the SDK current.
- Devices only accept an install if their firmware meets the minimums declared
  in the SDK's device file (`~/.Garmin/ConnectIQ/Devices/<id>/compiler.json` →
  `partNumbers[].firmwareVersion` / `connectIQVersion`). For this Venu 2S those
  are `1905` / `5.0.0`, and the watch reports exactly `19.05` — so builds for it
  are installable, but keep that in mind when targeting older watches.
- You need the **same signing key** for later versions, which is why losing the
  key is fatal.

---

## 11. Gotcha index

| Symptom | Real cause |
|---|---|
| `Invalid device id specified: 'venu2s'` | SDK device metadata not downloaded (§3) |
| `Unable to load private key: ... unknown version: 3` | Passed a `.p12`; export to PKCS#8 DER |
| `A string resource matching the provided app name can't be found` | Manifest `name` is a literal, not `@Strings.X` |
| `Cannot resolve type 'Dc'` | Missing `import Toybox.Graphics;` |
| `.prg` still in `APPS` after ejecting | Not installed — only a **physical unplug** installs it |
| `.prg` gone from `APPS`, app absent | It was ingested and rejected — read `CIQ_LOG.YML` (§7) |
| `Signature check failed` | wrong device / SDK too old / **key < 4096 bit** (§7) |
| `gio mount` says `Couldn't find matching udev device` | Watch is in **Garmin** mode, not MTP (`091e:0003`) |
| `gio list` hangs or errors on a path | Use the `mtp://` URI with `%20` for `Internal Storage` |
| SSH/keytool step asks for a password | `keytool -genkey` uses `-storepass`; there is no interactive prompt here |
