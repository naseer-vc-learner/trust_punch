# TrustPunch

Attendance module of an HRMS, built as a **demonstration**. Fully offline: no
backend, no network, no accounts. Everything lives on the device in
`shared_preferences`.

Target device is a physical iPhone — the iOS simulator has no camera, so
enrollment and check-in cannot run there.

## Run it

```bash
flutter run -d 00008101-00042D461105001E --debug     # the connected iPhone
flutter devices                                      # if the id changed
dart analyze lib                                     # must stay clean
```

**Only ever have one `flutter run` alive.** Two sessions fight over the device
and the second hangs on "Installing and launching…" forever with no error.
Kill first:

```bash
pkill -f "dartvm.*run -d"; pkill -f "devicectl device process launch"
```

## Layout

```
lib/
  main.dart                      app root; rebuilds on language change, applies RTL
  src/
    models/attendance.dart       Worker, Site, Punch, WorkerStatus, cosineSimilarity
    store/attendance_store.dart  all state + persistence + hours/break/flag maths
    i18n/phrases.dart            spoken lines + language list
    i18n/ui_text.dart            on-screen text (enum T), isRtl()
    services/
      face_recognizer.dart       TFLite embeddings, 1:1 verify + 1:N identify + duplicate check
      face_capture_service.dart  front camera + ML Kit stream
      liveness_detector.dart     blink / head-turn verdict
      location_service.dart      GPS fix, 50 m geofence, site ranking
      integrity_service.dart     jailbreak / emulator check
      speech_service.dart        TTS, voice availability, fallback voices
      supervisor_lock.dart       supervisor PIN: salted hash, lockout after 5 tries
    screens/                     home, verify, enroll, workers, sites, calendar,
                                 supervisor_pin (PIN dialogs)
test/                            supervisor lock + shift flags (`flutter test`)
assets/models/mobilefacenet.tflite   112×112 → 192-dim embedding
_old_firebase_app/               the previous Firebase version, kept for reference
```

## How a punch works

`home → VerifyScreen` proves four things in order, and refuses at the first
failure: device not jailbroken → GPS fix is real, precise to ±30 m, and
within 50 m of a known site → liveness challenge passed → face matches
someone enrolled.

Then `allowedActions()` decides what is legal next. If only one action is
possible it happens without asking; only a worker already on the clock is
offered a choice (finish vs break).

## Decisions worth not re-litigating

- **No Firebase.** It was removed deliberately; App Check could not work
  against a placeholder project and its failures were corrupting auth headers.
  The old code is in `_old_firebase_app/` if you need to look.
- **This is not a git repo.** Nothing is recoverable. Move files aside rather
  than deleting them.
- **SPM is disabled** (`flutter config --no-enable-swift-package-manager`).
  ML Kit is CocoaPods-only, and the hybrid SPM+CocoaPods setup produced
  missing-XCFramework build failures. If those return:
  `rm -rf build/ios/SourcePackages && cd ios && pod install`.
- **Podfile forces every pod to iOS 15.5.** Xcode 27 treats a lower deployment
  target as a hard error, and this Flutter SDK's helper predates it.
- **Android needs minSdk 26** for `tflite_flutter` (already set).
- **`android/build.gradle.kts` pins `tflite_flutter`'s Kotlin to JVM 11.** The
  plugin sets Java 11 but no Kotlin target, so on JDK 25 the build fails with
  "Inconsistent JVM Target Compatibility". Remove only if the plugin fixes it.
- **Supervisor PIN guards Workers, Sites, the mode switch, the phone's owner
  and "Delete all attendance".** Set on first use. A forgotten PIN means
  reinstalling the app (which wipes all data). Scan face is never behind it.
- **Work and break never overlap.** Break time is excluded from worked hours,
  not contained in it.
- **A session left open on a past day stops accruing.** Only today keeps
  counting, or a forgotten check-out would add whole days.
- **Check-out is pinned to the site the session opened at**, so hours cannot
  land against a site nobody worked.

## Known limits (matters before this is used for real)

- **Translations outside English are machine-written** — `phrases.dart` and
  `ui_text.dart` both need a native speaker. Wrong register reads worse than
  plain English.
- **iOS has no Malayalam or Urdu voice.** Urdu is spoken with the Hindi voice
  (same spoken language, different script); Malayalam is silent and its chip
  shows a mute icon. Telugu, Kannada and Arabic voices *are* available if
  needed.
- **Face thresholds are untuned defaults**: match 0.65, 1:N runner-up margin
  0.06, duplicate 0.58 (looser on purpose — refusing a re-registration costs a
  retry, allowing two identities for one face defeats the app). Test with real
  people and adjust in `face_recognizer.dart`.
- **2D recognition works within roughly 30–45° of frontal.** Three enrolled
  angles help; a true profile will not match.
- **Team mode (1:N) is inherently riskier than individual mode (1:1)** — every
  extra worker is another chance to be the closest match by accident.
- Shift rules are hardcoded: 09:00 start, 10 min grace, 8 h day
  (`attendance_store.dart`).
- **Supervisor screens are English-only** (PIN dialogs, delete-all); `t()`
  falls back to English. Worker-facing text is in all six languages.
- **The PIN lock stops casual misuse, not a rooted phone**: the hash and all
  other data sit in plain `shared_preferences`.
- **GPS accuracy limit is 30 m** (`maxFixAccuracyMeters`), also applied when
  saving a site. It may refuse honest check-ins indoors; tune with real sites.

## Possible next steps

Discussed but not built: store the verification selfie per punch, CSV export
for payroll, full-screen green/red result feedback, photo-based site and worker
identity, clock-tampering detection.
