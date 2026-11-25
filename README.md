# TrustPunch

Employee attendance where a check-in is verified by several independent signals,
so it cannot be faked, spoofed, or performed on someone else's behalf. Supports
on-site attendance (geofenced to a site radius, default 1 km) and work-from-home
attendance (face + liveness, no geofence).

**The security principle everything else follows from:** the Flutter client only
*captures* signals — a live face, GPS coordinates, a device id. It never decides
or writes "attendance approved". Verification and the decision happen in a Cloud
Function using the Admin SDK, and the Firestore rules deny client writes to
`attendance` entirely, so the client could not persist a verdict even if it were
compromised.

## What is here

```
lib/src/
  app/            app shell, sign-in gate, theme
  core/           Riverpod composition root
  data/
    models/       domain types mirroring the server contract
    services/     device, location, camera+ML Kit, callable API, offline queue
    repositories/ the submission pipeline
  features/       onboarding · home · capture · result · wfh · ping · admin
functions/        the verification backend (see functions/README.md)
firestore.rules   client writes to attendance are denied, always
storage.rules     selfies are written by the server, read by their owner
```

## Setup

1. **Firebase project.** `lib/firebase_options.dart` ships with placeholders that
   fail fast. Replace them:
   ```bash
   dart pub global activate flutterfire_cli
   flutterfire configure --project=<your-project-id>
   ```
   That also writes `android/app/google-services.json` and
   `ios/Runner/GoogleService-Info.plist`.

2. **Backend.**
   ```bash
   cd functions && npm install && npm test
   firebase deploy --only firestore:rules,storage,functions
   ```
   Set `TP_REGION` (or keep `europe-west1`) and make `TrustPunchApi.region` in
   `lib/src/data/services/trustpunch_api.dart` match.

3. **App Check.** Register the app under App Check in the console and turn on
   *enforcement* for Firestore, Functions and Storage. The callables already
   reject requests with no attestation token (`REQUIRE_APP_CHECK=true`), but
   enforcement is what stops direct REST access. Debug builds use debug
   providers; register the debug token from the console.

4. **Seed data.** Create `sites/*` documents and one `employees/{uid}` document
   per person (uid = their Firebase Auth uid). Both are admin-write-only by
   design — use the console or an admin script.

5. **First admin.** See the bootstrap snippet in `functions/README.md`.

6. **Firestore TTL.** Set a TTL policy on `liveness_challenges.expiresAt` so
   spent challenges are garbage-collected.

```bash
flutter pub get
flutter run
```

## How a check-in works

1. **Home** shows current status, live distance to the assigned site, and any
   captures still awaiting a verdict.
2. **Capture** asks the server for a liveness challenge (`blink twice`, `turn
   head left`, …), opens the front camera — there is no gallery picker anywhere
   in the app — and runs ML Kit on the frame stream. GPS is acquired in parallel.
3. The still is taken **the moment liveness is satisfied**, not on a tap: waiting
   for a button would let the photo be taken at a different moment than the
   challenge.
4. Everything goes to `submitCheckIn`, including the *raw* ML Kit measurements.
   The server re-derives whether the claimed action actually happened; the
   client's opinion that it passed is not an input.
5. **Result** shows the server's verdict and its message. If flagged, it shows
   the reason and the concrete next step.

## Offline

A capture that cannot reach the server is stored encrypted and shown as
**"Waiting to be confirmed"** — a distinct state from approved, in the model, in
the theme, and on the result screen. There is no code path that promotes a queued
item to approved without a server response. Queued items older than two minutes
are dropped rather than sent, because their liveness challenge has expired and
submitting them could only produce a confusing rejection.

## Biometrics and privacy

- `local_auth` is a **convenience gate only**. Passing the device biometric
  proves the phone's owner unlocked it, not who is in front of the camera, so the
  server still runs its own face match.
- Enrollment frames are never written to disk or Storage. They are posted, turned
  into one template, and dropped. Only the opaque `faceEmbeddingRef` persists.
- Audit selfies are kept per attendance record, including for rejected attempts —
  a failed spoof is exactly the evidence a security review needs.
- Root/jailbreak/emulator detection blocks submission client-side *and* the
  server re-checks, with a clear in-app message either way.

## Tests

```bash
flutter test                      # 39 tests
cd functions && npm test          # 76 tests
```

The backend suite covers the parts that must not silently break: Haversine
distance (including antimeridian, antipodes and Null Island), the geofence
accuracy grace band, mock-location rejection, both face-match thresholds,
liveness challenge expiry and replay, device-trust states, and the anomaly
patterns. The Flutter suite covers the liveness accumulator (a static photo never
satisfies a blink prompt), the offline queue's behaviour, and the screens'
refusal to present an unconfirmed capture as approved.

## Decisions I made that are yours to confirm

These were "propose a sensible default and flag it" calls:

- **Liveness prompt set** — `blink_twice`, `turn_head_left`, `turn_head_right`,
  `look_straight_then_left`. One prompt per challenge.
- **Match thresholds** — approve at 0.85, review band down to 0.70, reject below.
  These are placeholders until a real vendor is wired in; re-tune then.
- **Unregistered devices are flagged, not rejected** (`REJECT_UNREGISTERED_DEVICE`),
  so a genuine phone upgrade is not a lockout.
- **WFH is manager-approved, not self-service.** A WFH day switches off the
  geofence; if employees could grant it to themselves, location verification
  would be optional in practice.
- **Timezone `Asia/Dubai`** drives "today", ping windows and the daily sweep.
- **Working day 09:00–18:00**, weekends skipped for presence pings.

## Not built

- `workmanager` is a dependency but unused: presence pings are FCM-driven, which
  is more reliable than background scheduling on both platforms. Keep it if you
  want an offline-queue retry job; remove it otherwise.
- Site management is read-only in the admin view — `sites` writes are denied to
  clients, so adding sites needs the console or an admin-only callable.
