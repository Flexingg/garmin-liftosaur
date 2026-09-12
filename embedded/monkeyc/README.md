# Embedded workspace (Monkey C — Garmin Venu 2S)

Owner: Embedded Agent. Source lives in `source/`, resources in `resources/`,
`manifest.xml` declares the app, product targets, and permissions.

> **Full toolchain, signing, and sideload reference:**
> [`docs/03-garmin-toolchain-and-sideload.md`](../../docs/03-garmin-toolchain-and-sideload.md).
> That document is verified against real hardware and supersedes everything
> below — including how to start a brand-new Garmin app.

## Build (the supported path)

```bash
cd embedded/monkeyc
./tools/linux-build.sh venu2s        # default device is venu2s
```

The script locates the SDK (without trusting `$HOME`), **enforces a 4096-bit
signing key**, builds `bin/Liftosaur.prg`, and asserts the artifact targets the
expected device. Extra arguments are forwarded to `monkeyc`, e.g.
`./tools/linux-build.sh venu2s -r` for a release build.

Raw equivalent:

```bash
monkeyc -d venu2s -f monkey.jungle -o bin/Liftosaur.prg -y developer_key.der -w
```

## ⚠️ Signing key: RSA 4096 is mandatory

A **2048-bit** key builds fine and produces a *cryptographically valid*
signature, but the **watch rejects it** with:

```
Error: 'Signature check failed on file: Liftosaur'
```

A 4096-bit key works. This was isolated with a four-build experiment on real
hardware (see `docs/03`). `tools/linux-build.sh` now refuses keys under 4096
bits, so this cannot regress silently. The old rejected 2048-bit key is kept as
`developer_key.2048-rejected.der` purely as evidence — do not sign with it.

```bash
# generate a 4096-bit PKCS#8 DER key (monkeyc rejects .p12 keystores)
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out developer_key.pem
openssl pkcs8 -topk8 -nocrypt -in developer_key.pem -outform DER -out developer_key.der

# verify
openssl pkey -in developer_key.der -inform DER -text -noout | head -1
# -> Private-Key: (4096 bit, 2 primes)
```

Back the key up — you need the same one to update the app. Keys are
`.gitignore`d and must never be committed.
**Registering the key with Garmin is not required for sideloading.**

## Sideload to the watch

1. Watch → Settings → System → **USB Mode → MTP** (not "Garmin" mode), data cable.
2. `gio copy -p bin/Liftosaur.prg "mtp://<id>/Internal%20Storage/GARMIN/APPS/Liftosaur.prg"`
3. **Physically unplug the cable** — that is what installs it. A software eject does not.
4. On the watch press **START** (top-right) and find **Liftosaur** in the app list.

If it doesn't appear: replug and read `GARMIN/APPS/LOGS/CIQ_LOG.YML`.

## Toolchain install (if this machine is new)

```bash
sudo apt-get install -y openjdk-21-jdk-headless unzip curl openssl
curl -sL -o /tmp/ciq.tgz https://github.com/lindell/connect-iq-sdk-manager-cli/releases/download/v0.8.4/connect-iq-sdk-manager-cli_0.8.4_Linux_x86_64.tar.gz
tar -xzf /tmp/ciq.tgz -C ~/.local/bin
export GARMIN_USERNAME=... GARMIN_PASSWORD=...
connect-iq-sdk-manager agreement accept
connect-iq-sdk-manager sdk set 9.2.0
connect-iq-sdk-manager device download --manifest=manifest.xml -F     # per-device metadata is REQUIRED
```

## Hardware Checkpoint 1 — PASSED ✅ (2026-09-12)

- ✅ `Liftosaur.prg` sideloads to the Venu 2S (`006-B3704-00`, firmware 19.05)
- ✅ App installs, launches, and its state machine responds to Start/Stop
  (`IDLE → RECORDING → STOPPED`)
- ✅ No crash from the accelerometer polling at ~20 Hz

## App identity

The manifest `<iq:application id="...">` UUID is how the device identifies an
installed app. It is currently **pinned to the UUID of the build installed on
the watch**, so rebuilds update that app in place. Keep it stable; a new UUID
installs a *second* app alongside the existing one.
