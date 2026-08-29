# Embedded workspace (Monkey C — Garmin Venu 2)

Owner: Embedded Agent. Source lives in `source/`, resources in `resources/`,
`manifest.xml` declares the app, product targets, and permissions.

## Toolchain install (required to compile the `.prg`)

1. Install the **Garmin Connect IQ SDK** (Monkey C compiler is `monkeyc.bat`/`monkeyc`).
   - Download: https://developer.garmin.com/connect-iq/sdk/
   - Unzip somewhere like `C:\dev\connectiq-sdk`.
2. Optionally install the **Connect IQ VS Code extension** for building + device logs.
3. Set `CONNECTIQ_HOME` to the SDK dir, or use the extension's settings.
4. To sideload to a physical Venu 2 you need a **developer key** (from
   https://developer.garmin.com/connect-iq/program/ — free) and a **debug app** from the
   Garmin Connect Mobile app → Connect IQ → Developer → Debug App.

## Build + sideload

```bash
# one-time: create a dev key
keytool -genkey -keystore developer_key.p12 -alias developer -storetype PKCS12 \
  -validity 500 -storepass <pass> -dname "CN=Jonathan Randall"

# compile the .prg
monkeyc -d venu2 -f monkey.jungle -o bin/Liftosaur.prg \
  -y developer_key.p12 -w

# side-load: push via the debug app on the phone, or via `connectiq` CLI:
#   connectiq (Garmin Simulator) — for dev without hardware
```

## Hardware Checkpoint 1 (gates Phase 2)

- Sideload `Liftosaur.prg` to the Venu 2.
- Press **Start/Stop**.
- Verify in the VS Code device logs that the accelerometer arrays generate without the
  watch crashing from memory limits.
