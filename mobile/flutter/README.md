# Mobile workspace (Flutter — phone companion app)

Owner: Mobile Agent. Scaffolded with `flutter create` (project `liftosaur_garmin`).

```bash
cd /c/RandallEngineering/Garmin_Liftosaur/mobile/flutter
flutter run          # on the OPPO over wireless adb, or Windows desktop
```

## Phase 2 / 3 responsibilities

- BLE client for the watch chunks (contract: `docs/01-ble-payload-data-contract.md`).
- Liftosaur API auth + fetch of current program/exercise/prescribed weight (Phase 3;
  contract in `C:/RandallEngineering/RandallReps/liftosaur2sparky/sync.mjs`).
- Buffer CHUNK frames, concatenate on SET_END, POST to the backend
  (contract: `docs/02-backend-api-data-contract.md`).
