# Build prompt: TrustPunch — secure employee attendance app

> Paste everything below into Claude Code (model: Opus, thinking: medium). Work through it phase by phase rather than generating everything in one shot — ask Claude to confirm the plan for each phase before writing code if the codebase is new to you.

---

## 1. Project overview

Build a Flutter mobile app called **TrustPunch** for employee attendance tracking. The core requirement is that every check-in must be verified through multiple independent signals so it cannot be faked, spoofed, or done on someone else's behalf. The app supports both **on-site attendance** (geofenced to a 1km radius of a registered site) and **work-from-home attendance** (face + liveness only, no geofence).

**Non-negotiable security principle:** the Flutter client only *captures* signals (face image, GPS coordinates, device ID). It never decides or writes "attendance approved" itself. All verification and the final decision happen in a backend Cloud Function using the Firebase Admin SDK. Firestore security rules must deny direct client writes to the attendance collection.

---

## 2. Tech stack

- **Frontend:** Flutter (latest stable), state management with Riverpod
- **Backend:** Firebase (Firestore, Cloud Functions — Node.js/TypeScript, Firebase Auth, Firebase Storage, Firebase App Check, Firebase Cloud Messaging)
- **Face detection (on-device):** `google_mlkit_face_detection`
- **Face matching (server-side, inside Cloud Functions):** stub this behind an interface — implement a mock/local version for testing, but structure the code so it can be swapped for AWS Rekognition, Azure Face API, or self-hosted CompreFace later
- **Location:** `geolocator`
- **Local biometric unlock (secondary factor, not identity verification):** `local_auth`
- **Device fingerprinting:** `device_info_plus`
- **Secure local storage:** `flutter_secure_storage`
- **Camera (capture-only, no gallery picker):** `camera`
- **Background scheduling (WFH pings):** `workmanager`
- **Root/jailbreak detection:** a suitable package (e.g. `safe_device` or equivalent — pick the best-maintained option)

---

## 3. Firestore data model

Design and implement these collections (adjust field names as needed, but keep the structure):

```
employees/{employeeId}
  - name, email, role, registeredDeviceId, faceEmbeddingRef, assignedSiteIds[], status

sites/{siteId}
  - name, latitude, longitude, radiusMeters (default 1000)

attendance/{recordId}
  - employeeId, type ("onsite" | "wfh"), timestamp (server-set),
    faceMatchScore, gpsCoordinates, distanceFromSite, isMockLocationFlag,
    deviceId, deviceTrusted (bool), selfieStorageRef, status ("approved" | "flagged"),
    flagReason (nullable)

devices/{deviceId}
  - employeeId, registeredAt, approved (bool)

wfh_exceptions/{exceptionId}
  - employeeId, date, approvedBy, reason
```

Write the actual `Firestore Security Rules` file. Requirements:
- `attendance` collection: client can only **read** their own records (or admin can read all); **all writes** must be `false` for client requests — only the Admin SDK inside Cloud Functions can write.
- `employees`: employees can read their own doc; only admins can write.
- `devices`: employees can read their own; writes only via Cloud Function (device approval workflow).

---

## 4. Cloud Functions (the core logic)

Implement these as callable HTTPS Cloud Functions:

### `submitCheckIn`
Input: employeeId, base64 selfie, GPS coordinates + accuracy + `isFromMockProvider` flag (Android), device ID, type (`onsite`/`wfh`), siteId (if onsite).

Logic:
1. Verify device ID matches the employee's registered device (reject or flag if not, unless it's a pending-approval new device flow).
2. Run face match against the employee's stored embedding via the pluggable face-match interface. Reject below a configurable confidence threshold.
3. If `type == "onsite"`: compute Haversine distance from the site's coordinates; reject if outside `radiusMeters`; reject/flag if `isFromMockProvider` is true.
4. If `type == "wfh"`: skip geofence check; still require face match.
5. Assign `timestamp` using the server clock (`admin.firestore.Timestamp.now()`), never a client-supplied value.
6. Write the result to `attendance/{recordId}` using the Admin SDK with `status: "approved"` or `"flagged"` plus a `flagReason`.
7. Return only the outcome (approved/flagged + reason) to the client — not a writable object.

### `registerDevice`
Handles new-device requests; sets `approved: false` and notifies an admin for manual approval rather than auto-approving.

### `sendWfhPresencePing` (scheduled function)
Triggers 2–4 random times during work hours for WFH employees, sends an FCM push prompting a presence check within a short window (e.g. 5 minutes), and logs whether it was completed.

### `flagAnomalies` (scheduled function)
Runs daily. Flags patterns like: identical face-match scores across multiple days (possible replay attack), check-ins from wildly different locations within an implausible time gap, or a device suddenly associated with a different employee.

Write these with proper input validation, error handling, and TypeScript types. Include a short README section per function explaining what it checks and why.

---

## 5. Flutter app — screens and flows

1. **Onboarding / enrollment:** employee registers, captures 5–8 face angles for embedding generation, registers current device, sets up local biometric unlock.
2. **Home / check-in screen:** shows current status, a check-in button, and (for onsite) current distance from assigned site.
3. **Capture flow:** opens camera (no gallery picker allowed), issues a random liveness challenge (e.g. "blink twice," "turn head left") generated server-side or from a random local set validated server-side, captures GPS in parallel, submits everything to `submitCheckIn`.
4. **Result screen:** shows approved/flagged outcome. If flagged, shows the reason and next steps (e.g. "contact your manager").
5. **WFH mode toggle:** employee (or their manager, per your approval workflow) marks a day as WFH; this changes which check-in flow is used and disables the geofence requirement for that day.
6. **Admin dashboard (can be a simple web or Flutter-web view):** attendance records, flagged events queue, device approval queue, site management (add/edit geofenced sites).
7. **Presence-ping response screen:** appears when an FCM WFH ping arrives, requires a quick face capture within the response window.

---

## 6. Non-functional requirements

- Handle offline gracefully: queue a check-in attempt locally if there's no connectivity, and clearly show the employee it hasn't been confirmed yet — never mark it as approved until the server responds.
- Do not store raw face images anywhere long-term beyond what's needed for the audit selfie (store embeddings for matching, not the enrollment photos, once matching is set up).
- Add root/jailbreak detection and block check-in submission on compromised devices, with a clear in-app message.
- Write unit tests for the Cloud Functions verification logic (Haversine calculation, mock-location rejection, threshold checks) — this is the part that must not silently break.
- Add basic integration tests for the check-in flow in Flutter (widget tests are fine for a testing-stage build).

---

## 7. Build order (work through these phases, confirming each before moving on)

1. Scaffold the Flutter project structure and Firebase project config (use placeholder config values — I'll swap in real ones).
2. Implement Firestore schema + security rules.
3. Implement the Cloud Functions (`submitCheckIn` first, with a mocked face-match function so it's testable without a real vendor API key).
4. Build the enrollment and check-in Flutter screens, wiring to the Cloud Functions.
5. Add the WFH flow and presence-ping scheduled function.
6. Add the anomaly-detection scheduled function and a minimal admin view for flagged records.
7. Add tests for the verification logic.

Ask me for any Firebase project details, vendor API keys, or design preferences you need before proceeding — don't invent placeholder business logic where a real decision is needed (e.g. exact liveness challenge set, exact match-score threshold — propose sensible defaults and flag them as configurable).
