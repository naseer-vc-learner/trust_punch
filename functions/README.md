# TrustPunch backend

Every attendance decision is made here. The Flutter client captures signals and
displays a verdict; it never computes one, and the Firestore rules deny it write
access to `attendance`, `devices` and `employees` so it could not persist one
even if it tried.

## Layout

| File | Role |
| --- | --- |
| `src/verification.ts` | The decision engine. Pure — no Firestore, no clock, no network. |
| `src/lib/geo.ts` | Haversine distance and implied-speed maths. |
| `src/lib/guards.ts` | Auth, App Check and payload validation for every callable. |
| `src/config.ts` | Every tunable threshold, overridable by env var. |
| `src/faceMatch/` | Pluggable face vendor behind one interface. |

`verification.ts` is deliberately free of dependencies: the rules that decide
whether attendance counts are unit tested exhaustively (`test/verification.test.ts`,
35 cases) and cannot silently break when Firebase changes underneath them.

## Functions

### `submitCheckIn` (callable)

The only path by which an attendance record can come into existence.

What it checks, and why:

- **App Check + Auth** — proves the call came from a genuine build of the app and
  a signed-in user. `employeeId` is read from the auth token, never the request
  body, so nobody can punch in on someone else's behalf.
- **Device binding** — the device id must match the employee's registered,
  admin-approved device. A device already bound to another employee is the
  classic buddy-punching signal and is always flagged.
- **Liveness challenge** — a server-issued, single-use, 90-second prompt. The
  claimed action is re-derived from the raw ML Kit telemetry the client sends
  (eye-open probability range, head yaw range), so the client's own opinion that
  it "passed" is not an input. Defeats a printed photo or a recorded video.
- **Face match** — via the pluggable vendor, with two thresholds. Below
  `FACE_REVIEW_THRESHOLD` rejects; between review and `FACE_APPROVE_THRESHOLD`
  records the punch but flags it for a human.
- **Geofence** (on-site only) — Haversine distance against the site radius, with
  the GPS accuracy circle allowed as grace at the fence line. `isFromMockProvider`
  rejects outright, and outranks distance: a spoofed fix that lands *inside* the
  fence is worse than an honest one outside it.
- **Server clock** — `timestamp` is `Timestamp.now()` on the server. No
  client-supplied time is ever read, so back-dating is impossible.
- **Idempotency** — `clientNonce` is unique per capture attempt, so the offline
  queue can retry without creating duplicate punches.

Fails closed: if the face vendor is unreachable, the call returns `unavailable`
rather than approving.

Returns only `{recordId, status, flagReason, message, distance, serverTimestamp}`.
The client never receives a writable object.

### `issueLivenessChallenge` (callable)

Issues the prompt. Server-side because a locally chosen prompt is predictable,
and a predictable prompt can be pre-recorded. Single-use is enforced by a
Firestore transaction inside `submitCheckIn`, so two concurrent submissions
cannot both consume the same challenge — a replayed capture loses the race.

### `registerDevice` (callable)

Records a device request; it never grants trust. New devices are written with
`approved: false` and an admin is notified. The only exception is an employee's
very first device, auto-approved because enrollment already happened in person
and there is nothing yet to defend.

Refuses to overwrite a device already claimed by another employee — that is
exactly how a shared handset would launder itself between people.

### `approveDevice` / `reviewAttendanceRecord` / `setAdminClaim` (callable, admin)

Admin actions still go through functions rather than direct writes, because the
rules deny `attendance` writes to *everyone*. That leaves exactly one auditable
code path per record. `reviewAttendanceRecord` records who accepted a flagged
punch and never clears `allFlagReasons`, so history cannot be quietly rewritten.

Admin identity is a custom auth claim, not a Firestore field — no document write
can escalate privilege.

### `enrollFace` / `resetFaceEnrollment` (callable)

Turns 5–8 captured angles into one template. The frames are decoded in memory,
handed to the matcher and dropped when the request ends; only the opaque
`faceEmbeddingRef` survives, so there is no enrollment photo set to leak.
Enrollment is once-only — re-enrolling would let someone holding a brief session
replace the stored identity with their own face. `resetFaceEnrollment` is both
the re-enrollment path and the GDPR erasure path.

### `planPresencePings` / `dispatchPresencePings` (scheduled)

`planPresencePings` runs each working morning and draws 2–4 random minutes across
the whole working day for every employee with an approved WFH exception.
`dispatchPresencePings` runs every 5 minutes, sends the due ones by FCM with a
hard deadline, and closes out windows that elapsed unanswered.

Planned ahead rather than rolled per tick: an employee who notices the dispatcher
only fires at :00 and :30 can be present only at those moments. Times drawn once
from the whole day are unguessable from the outside.

A missed ping is recorded as evidence, not punishment — it lands in the flagged
queue for a manager to interpret.

### `respondToPresencePing` (callable)

Accepts the verdict of a check-in that already went through `submitCheckIn`, and
only if that record belongs to the caller. The response requires a real face
capture: a ping answered by tapping "yes" would prove only that a phone was
unlocked.

### `flagAnomalies` (scheduled, daily)

Per-check-in verification only sees one moment. This sweep looks at a week:

- **Replayed face scores** — a real camera never produces the identical match
  score on three different days. Identical scores mean the same bytes were
  submitted repeatedly.
- **Impossible travel** — two check-ins whose separation implies faster-than-
  airliner movement. One of them was not where it claimed.
- **Device drift** — one device id appearing under multiple employees.

It never deletes or reverses a record; it downgrades status to `flagged` with a
reason and leaves the judgement to a human, because each of these has an innocent
explanation often enough to matter.

## Configuration

All thresholds live in `src/config.ts` and read from env (`functions/.env`).
The defaults below are **my proposals, not policy** — review them before going
live:

| Setting | Default | Note |
| --- | --- | --- |
| `FACE_APPROVE_THRESHOLD` | `0.85` | Vendor-specific. Re-tune when you swap the mock out. |
| `FACE_REVIEW_THRESHOLD` | `0.70` | Below this rejects outright. |
| `DEFAULT_SITE_RADIUS_METERS` | `1000` | Per the spec; overridable per site. |
| `MAX_GPS_ACCURACY_METERS` | `100` | Vaguer than this flags rather than trusts. |
| `LIVENESS_CHALLENGE_TTL_SECONDS` | `90` | |
| `LIVENESS_MIN_FRAMES` | `12` | Rejects a single still frame. |
| `IMPOSSIBLE_TRAVEL_KMH` | `900` | Roughly cruising speed. |
| `WFH_MIN_PINGS` / `WFH_MAX_PINGS` | `2` / `4` | |
| `WFH_RESPONSE_WINDOW_MINUTES` | `5` | |
| `BLOCK_COMPROMISED_DEVICES` | `true` | |
| `REJECT_UNREGISTERED_DEVICE` | `false` | Flags instead, so a phone upgrade is not a lockout. |
| `TP_TIMEZONE` | `Asia/Dubai` | Drives "today", ping scheduling, daily sweeps. |
| `TP_REGION` | `europe-west1` | Must match `TrustPunchApi.region` on the client. |

## Face matching

`MockFaceMatcher` is a byte-histogram similarity, not face recognition. It
exercises every branch of the pipeline offline without an API key, and refuses to
start in a project whose id looks like production.

To plug in a real vendor: implement `FaceMatcher` (three methods) in
`src/faceMatch/`, add a case to `getFaceMatcher()`, set `FACE_MATCH_PROVIDER`.
Nothing in `verification.ts` or its tests changes.

## Commands

```bash
npm install
npm test          # 76 tests, no emulator or network required
npx tsc --noEmit  # typecheck
npm run serve     # emulators: functions, firestore, auth, storage
npm run deploy
```

## Bootstrapping the first admin

`setAdminClaim` requires an existing admin, so the first one is set from a
trusted shell:

```js
await admin.auth().setCustomUserClaims(uid, { admin: true });
```

The user must sign out and back in for the new claim to appear in their token.
