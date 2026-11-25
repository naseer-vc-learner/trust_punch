# Local testing — guaranteed zero cost

Runs the entire stack on your machine: Auth, Firestore, Functions and Storage.
**No Firebase project, no login, no billing account, no deploy.**

What guarantees that is the project id `demo-trustpunch`. The `demo-` prefix is
special to the Firebase tooling — it treats the project as one that does not
exist and refuses to reach any real service. The emulator says so on startup:

```
Detected demo project ID "demo-trustpunch", emulated services will use a demo
configuration and attempts to access non-emulated services for this project will fail.
```

There is no path by which a local run can produce a bill.

## Prerequisites

Already present on this machine — listed so you can reproduce it elsewhere.

| | Needed for | Check |
|---|---|---|
| Java 11+ | Firestore + Storage emulators | `java -version` |
| Node 20+ | Functions runtime | `node --version` |
| Firebase CLI | the emulator suite | `firebase --version` |

## Run it

**Terminal 1 — the backend:**

```bash
./scripts/emulators.sh
```

Builds the functions and starts everything. First run downloads ~100 MB of
emulator jars. Wait for `All emulators ready!`.

**Terminal 2 — test data:**

```bash
node scripts/seed-emulator.js
```

Creates one site, 10 users (1 admin, 1 manager, 8 employees) and an approved
WFH day for `employee1`, so the work-from-home path is testable immediately
rather than needing an approval round-trip first.

All accounts use password `Test123!`:

| Email | Role |
|---|---|
| `admin@test.local` | admin — sees the admin dashboard |
| `manager@test.local` | manager |
| `employee1@test.local` … `employee8@test.local` | employee |

**Terminal 3 — the app.** Which command depends on where it runs:

```bash
# iOS simulator / Android emulator — the defaults already work
flutter run --dart-define=USE_EMULATOR=true

# PHYSICAL PHONE — must be told your Mac's LAN IP
flutter run \
  --dart-define=USE_EMULATOR=true \
  --dart-define=EMULATOR_HOST=$(ipconfig getifaddr en0)
```

The flags are build-time, not runtime. A release build compiled without
`USE_EMULATOR` cannot be talked into emulator mode — an app that could be
pointed at a local server would be an app whose verification could be pointed at
a local server.

Watch for the startup line confirming which backend you hit:

```
⚠️  TrustPunch is running against LOCAL EMULATORS at 192.168.x.x.
```

### Physical device — read this first

**You want a real device for this app.** The iOS simulator has no camera at all,
so enrollment and check-in cannot run there. GPS, biometrics and root detection
are also either absent or faked on simulators. The emulator path is fine for
poking at screens; only a real phone exercises the actual verification.

Three things have to line up:

1. **Same Wi-Fi.** Phone and Mac on one network, with client isolation off (some
   guest networks block device-to-device traffic entirely).
2. **Emulators bound to `0.0.0.0`.** Already set in `firebase.json`. The default
   binds to loopback only, which a phone can never reach.
3. **`EMULATOR_HOST` set to your Mac's LAN IP.** `ipconfig getifaddr en0`.
   Note this changes when you move between networks — re-run the command.

Check reachability from the phone's browser before blaming the app:
`http://<your-mac-ip>:4000` should load the Emulator UI. If it does not, it is
a network problem, not a TrustPunch one.

iOS also needs an ATS exception to allow plain HTTP to a LAN address, and iOS 14+
prompts for local network permission on first connect — **say yes, or every call
fails**. Both are already configured in `Info.plist`
(`NSAllowsLocalNetworking`, `NSLocalNetworkUsageDescription`); the exception is
scoped to the local network and does not weaken ATS for internet traffic.

## Verify the backend without the app

```bash
node scripts/smoke-test.js
```

Drives the real callables in the real order — sign in, register device, enroll
face, request challenge, check in — then deliberately fails a check-in four ways
and asserts each rejection. Useful as a regression check after touching
`verification.ts`.

## What you can and cannot test locally

**Works fully:** sign-in, enrollment, device registration and approval, the
whole check-in path with face match and geofence, liveness challenge issue and
replay rejection, the offline queue, flagged-record review, the admin dashboard,
security rules (the emulator enforces `firestore.rules` exactly as the cloud does
— try writing to `attendance` from the Emulator UI and watch it refuse).

**Does not work locally, by nature:**

- **FCM push.** No delivery in the emulator, so WFH presence pings never arrive
  on the device. Test `PresencePingScreen` by navigating to it directly, or use
  the widget tests which cover both its states.
- **Scheduled functions.** `planPresencePings`, `dispatchPresencePings` and
  `flagAnomalies` load but never fire on their own. Trigger one by hand:
  ```bash
  curl -X POST "http://localhost:5001/demo-trustpunch/europe-west1/flagAnomalies"
  ```
- **App Check.** No attestation service locally. The client skips activation and
  the callables relax the matching check when they see `FUNCTIONS_EMULATOR` —
  a deployed function can never take that path.
- **Real face recognition.** The `MockFaceMatcher` is byte-histogram similarity,
  not recognition. It validates the plumbing, not the security: it will happily
  match the wrong person. Only a real vendor tells you whether the thresholds in
  `config.ts` are right.

## Data between runs

`scripts/emulators.sh` passes `--import`/`--export-on-exit`, so enrolled users
and their face templates survive a restart in `./.emulator-data` (gitignored).

Start clean:

```bash
rm -rf .emulator-data
```

## Ports

| Service | Port |
|---|---|
| Emulator UI | http://localhost:4000 |
| Firestore | 8080 |
| Auth | 9099 |
| Functions | 5001 |
| Storage | 9199 |
| Pub/Sub | 8085 |

The Emulator UI is worth having open — you can watch `attendance` documents
appear with their `flagReason` as you test, which makes the verification logic
much easier to reason about than reading logs.

## Moving to a real project later

Nothing here needs undoing. Run `flutterfire configure --project=<real-id>` to
overwrite `firebase_options.dart`, then drop the `--dart-define` flag. The
emulator path is only reachable with the flag set.
