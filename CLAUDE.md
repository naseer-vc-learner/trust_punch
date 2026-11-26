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
    models/leave.dart            LeaveRequest (annual/sick/unpaid; pending/approved/rejected)
    models/project.dart          Project (jobs = activities, roles); Site carries projectId + shift
    models/requests.dart         OvertimeDecision, CorrectionRequest (pending/approved/rejected)
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
      punch_photo_store.dart     small selfie per punch, app support dir, delete-all
      shift_reminders.dart       shift-end notification on "My own phone" (local, inexact)
    screens/
      role_root.dart             role picker + which home to show; supervisor idle lock
      worker_home.dart           "My own phone" (1:1): next-action button, my calendar/leave
      kiosk_home.dart            "Gate phone" (1:N): scan face, request leave, today's list
      supervisor_home.dart       on-site board, leave approvals, calendar, workers, projects
      project_screens.dart       projects: Today dashboard tab + Setup tab (jobs,
                                 roles, locations + shifts, workers)
      punch_result_screen.dart   full-screen green success / red failure, photo thumb
      approvals_screens.dart     overtime + correction approvals; "Fix a missed punch" form
      location_map.dart          OpenStreetMap preview of locations with the 50 m circle
    demo/demo_data.dart          load / remove a tagged demo week (supervisor flask menu)
      shared_widgets.dart        runPunch(), WorkerCard, ClockCard, VoiceBar, formatHours
                                 + verify, enroll, workers, sites, calendar, leave,
                                 supervisor_pin (PIN dialogs)
test/                            lock, shift flags, leave, roles, projects, punch
                                 evidence + dashboard, approvals, reminders,
                                 demo data, map (`flutter test`)
assets/models/mobilefacenet.tflite   112×112 → 192-dim embedding
_old_firebase_app/               the previous Firebase version, kept for reference
```

## How a punch works

`runPunch()` (worker or kiosk home) → `VerifyScreen` proves four things in order, and refuses at the first
failure: device not jailbroken → GPS fix is real, precise to ±30 m, and
within 50 m of a known site → liveness challenge passed → face matches
someone enrolled.

It also refuses a worker at another project's location (`canPunchAt`).
Then `planAt(worker, site)` decides what is legal next, and any automatic
check-out to record first. If only one action is possible it happens without
asking; only a worker already on the clock at this location is offered a
choice (finish vs break). `runPunch()` plans again at save time and writes the
automatic check-out and the punch together (`recordPunch`).

## Decisions worth not re-litigating

- **No Firebase.** It was removed deliberately; App Check could not work
  against a placeholder project and its failures were corrupting auth headers.
  The old code is in `_old_firebase_app/` if you need to look.
- **Git repo, remote is public on GitHub** (`origin` →
  `naseer-vc-learner/trust_punch`). Check what a commit adds before pushing;
  `.gitignore` covers build output, secrets, signing files and office docs.
  `_old_firebase_app/` predates git, so still move files aside rather than
  deleting them when unsure.
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
- **Three roles, picked on a start screen** (demo choice): Worker "My own
  phone" (1:1 against the owner the supervisor sets), Gate kiosk (1:N), and
  Supervisor. Worker and kiosk are remembered across restarts; supervisor
  never is. "Change user" returns to the picker from any home, with no PIN.
- **Supervisor PIN is entered once, at the picker**, and opens an in-memory
  session (`SupervisorLock.beginSession`) so screens inside don't ask again.
  It ends on "Change user", on restart, or after 2 min in the background.
  Only the supervisor home reaches Workers, Sites, the phone's owner, leave
  decisions and "Delete all attendance". Set on first use; a forgotten PIN
  means reinstalling the app (which wipes all data).
- **The kiosk never lists leave**, only files requests: a gate screen anyone
  can read is no place for other people's sick-leave reasons.
- **Leave: anyone may request, only the supervisor PIN decides.** The worker
  may be the one asking at a gate phone. Approve / reject / delete ask for the
  PIN once per visit to the Leave screen. Only *approved* leave marks a worker
  away; a worker can't hold two pending/approved requests sharing a day, and a
  decided request can't be re-decided.
- **Work and break never overlap.** Break time is excluded from worked hours,
  not contained in it.
- **A session left open on a past day stops accruing.** Only today keeps
  counting, or a forgotten check-out would add whole days.
- **Projects own locations and workers.** A worker is on one project with a
  role and a job (activity), and may punch at any of its locations, no other.
  Sites and workers from before projects existed are moved into "General"
  on first load (`generalProjectId`). A project with locations or workers
  can't be deleted.
- **Moving location without checking out closes the old one automatically**
  (replaces the old "check-out is pinned to its site" rule). The close time
  is the new check-in minus estimated travel (straight-line distance at
  30 km/h), never before the last punch there. The gap is shown as Travel,
  not counted as work; the punch is marked `auto` and the day gets an
  "Auto check-out" flag for the supervisor.
- **A session left open on an earlier day is closed at that location's
  shift end** when the worker next checks in, instead of accruing.
- **Each location has its own shift** (default 09:00–17:00). Late = first
  check-in of the day after that location's start + 10 min. Overtime/short
  stay against a fixed 8 h day across all locations.

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
- Grace (10 min), the 8 h day and the 30 km/h travel speed are constants in
  `attendance_store.dart`. Overnight shifts (end before start) are refused.
- **Travel is an estimate**: straight-line distance ignores roads, so real
  journeys are longer; the auto check-out time is shown as estimated.
- **Project screens are English-only**, like the other supervisor screens.
- **Punches are kept in time order** (`_insertSorted`; old saves sorted on
  load), because corrections insert punches in the past and every hours
  calculation walks a day's punches in list order.
- **Overtime = worked beyond 8 h/day; paid only once approved.** Finished
  days with overtime wait in "Overtime approvals". `payableOn` = up to 8 h
  plus the approved minutes (capped at that day's overtime). Decisions are
  final, like leave.
- **Corrections cover a missed check-in or check-out only**, need a reason,
  and change nothing until approved. An approved check-out replaces the
  closing punch of the session its time falls in (usually an automatic
  one); an approved check-in replaces a later check-in that started the same
  session; otherwise the punch is added. The day must still pass
  `validDay`, or approval is refused and the request stays pending. Approved
  punches are marked `corrected`; the request keeps what it replaced.
- **Clock checks:** a punch is refused when the phone's clock is more than
  2 min earlier than the newest punch on the phone (clock set back). It is
  flagged `clockSuspect` (not refused) when the phone's clock differs from
  the GPS fix time by more than 5 min.
- **Demo data is tagged and removable.** The supervisor's flask menu loads
  project `demo-project` ("Al Wasl Tower (demo)"), sites `demo-site-a/b` in
  Dubai, workers `demo-w1..5` with **no face data** (so no real face can
  match them), and the last six working days plus today up to now —
  generated through `planAt`/`recordPunch`, so auto check-outs and travel
  are real. "Remove demo data" deletes exactly those ids and their records
  (`removeRecordsOf`). Bulk writes use `AttendanceStore.batch`, which holds
  every `_saveX` until the end.
- **Shift-end reminders only on "My own phone"**: check-in / end of break
  schedules one for that location's shift end (if still ahead), check-out
  cancels it; gate phones never schedule. Inexact scheduling, so no
  exact-alarm permission; failures never block a punch. Android needs
  desugaring + the two receivers in the manifest; iOS sets the
  notification delegate in `AppDelegate.swift`.
- **A small selfie is kept per punch** (≤360 px, JPEG 70, file name on
  `Punch.photo`) as evidence; the full-size camera photo and the rotated
  temp copy are deleted right after use, at check-in and enrolment alike.
  Selfies live in the app support folder, show in the calendar and the
  green result screen, and are removed by "Delete all attendance" — there
  is no age-based retention yet. Android backup and device transfer are off
  (`allowBackup=false` + `data_extraction_rules.xml`); **iOS files are not
  yet excluded from iCloud/computer backup.**
- **Locations can be added by typed coordinates** (supervisor only, range
  checked; a "lat, long" pair pasted from a map app is split). They skip the
  30 m GPS check, so a typo puts the 50 m circle in the wrong place — the
  coordinates show under each location to check against a map.
- **Supervisor screens are English-only** (PIN dialogs, delete-all); `t()`
  falls back to English. Worker-facing text is in all six languages.
- **The PIN lock stops casual misuse, not a rooted phone**: the hash and all
  other data sit in plain `shared_preferences`.
- **Leave is a record, not a policy**: no balances or entitlements, days are
  calendar days (weekends included), and approved leave does not stop a
  check-in (both chips show). The Leave screen is English-only; only the
  "On leave" chip is in all six languages.
- **GPS accuracy limit is 30 m** (`maxFixAccuracyMeters`), also applied when
  saving a site. It may refuse honest check-ins indoors; tune with real sites.
- **The GPS clock check only means something on Android**: iOS reports fix
  times from the phone's own clock, so it never disagrees. The
  "clock set back" check works on both, but only after at least one punch.
- **Reminders can arrive a few minutes late** (inexact scheduling) and only
  if the worker allowed notifications. Correction and overtime screens are
  English-only, like the other supervisor screens; the "Fix a missed punch"
  button and the reminder text are in all six languages.
- **The location map is the app's only network use**, and only when a
  supervisor opens it: OpenStreetMap tiles (identified as
  `com.example.trust_punch`, credit shown as the licence requires). Fine
  for a demo; OSM's tile policy does not allow heavy production use, so a
  real deployment needs its own or a commercial tile provider. Offline it
  shows a banner; nothing else depends on it.

## Possible next steps

Discussed but not built: CSV/Excel payroll export (with payable hours),
photo-based site and worker identity, iOS backup exclusion for selfies and
data.
