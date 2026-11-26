import 'dart:math';

import '../models/attendance.dart';
import '../models/leave.dart';
import '../store/attendance_store.dart';

/// Fills the app with a believable week, so the dashboard, calendar,
/// approvals and reports can be shown anywhere, without walking between
/// sites or registering real faces.
///
/// Everything it adds is tagged (`demo-` ids, its own project) so
/// [removeDemoData] takes out exactly that and nothing real. Demo workers
/// have no face data, so no real face can ever match them at a check-in.

const demoProjectId = 'demo-project';
const _demoPrefix = 'demo-';

bool hasDemoData(AttendanceStore store) =>
    store.projectById(demoProjectId) != null;

// Two gates about 2.5 km apart in Dubai: ~5 minutes of estimated travel.
const _gateA = Site(
  id: 'demo-site-a',
  name: 'Gate A (demo)',
  latitude: 25.2048,
  longitude: 55.2708,
  projectId: demoProjectId,
  shiftStartMinutes: 7 * 60,
  shiftEndMinutes: 16 * 60,
);
const _gateB = Site(
  id: 'demo-site-b',
  name: 'Gate B (demo)',
  latitude: 25.2270,
  longitude: 55.2708,
  projectId: demoProjectId,
  shiftStartMinutes: 8 * 60,
  shiftEndMinutes: 17 * 60,
);

Worker _worker(String n, String name, String role, String job) => Worker(
  id: '${_demoPrefix}w$n',
  employeeId: 'D-10$n',
  name: name,
  embeddings: const [],
  projectId: demoProjectId,
  role: role,
  job: job,
);

final _asha = _worker('1', 'Asha', 'Mason', 'Block A foundation');
final _ravi = _worker('2', 'Ravi', 'Electrician', 'Block B MEP');
final _imran = _worker('3', 'Imran', 'Helper', 'Block A foundation');
final _joseph = _worker('4', 'Joseph', 'Foreman', 'Facade');
final _kumar = _worker('5', 'Kumar', 'Helper', 'Facade');

/// Loads the demo week ending at [now]. Does nothing if it is already there.
Future<void> loadDemoData(AttendanceStore store, {DateTime? now}) async {
  if (hasDemoData(store)) return;
  final at = now ?? DateTime.now();
  final today = DateTime(at.year, at.month, at.day);
  // Seeded, so every demo looks the same.
  final random = Random(7);
  Duration jitter(int minutes) =>
      Duration(minutes: random.nextInt(minutes * 2 + 1) - minutes);

  await store.batch(() async {
    await store.addProject('Al Wasl Tower (demo)', id: demoProjectId);
    await store.updateProject(
      store
          .projectById(demoProjectId)!
          .copyWith(
            jobs: ['Block A foundation', 'Block B MEP', 'Facade'],
            roles: ['Mason', 'Electrician', 'Helper', 'Foreman'],
          ),
    );
    await store.addSite(_gateA);
    await store.addSite(_gateB);
    for (final w in [_asha, _ravi, _imran, _joseph, _kumar]) {
      await store.addWorker(w);
    }

    // Punches through the same rules as a real check-in, so automatic
    // check-outs and travel come out exactly as they would in use.
    // Anything later than [at] is skipped: the demo never invents the future.
    Future<void> punch(
      Worker w,
      PunchType type,
      Site site,
      DateTime time, {
      bool clockSuspect = false,
    }) async {
      if (time.isAfter(at)) return;
      final plan = store.planAt(w.id, site, now: time);
      if (!plan.actions.contains(type)) return;
      await store.recordPunch(
        plan,
        Punch(
          type: type,
          at: time,
          workerId: w.id,
          employeeId: w.employeeId,
          workerName: w.name,
          siteId: site.id,
          siteName: site.name,
          latitude: site.latitude,
          longitude: site.longitude,
          distanceMeters: 12,
          clockSuspect: clockSuspect,
        ),
      );
    }

    DateTime t(DateTime day, int h, [int m = 0]) =>
        day.add(Duration(hours: h, minutes: m));

    Future<void> normalDay(
      Worker w,
      Site site,
      DateTime day, {
      int lateMinutes = 0,
      int stayMinutes = 0,
    }) async {
      final start = site
          .shiftStartOn(day)
          .add(Duration(minutes: lateMinutes) + jitter(4));
      await punch(w, PunchType.checkIn, site, start);
      await punch(w, PunchType.breakStart, site, t(day, 12, 30).add(jitter(5)));
      await punch(w, PunchType.breakEnd, site, t(day, 13, 15).add(jitter(5)));
      await punch(
        w,
        PunchType.checkOut,
        site,
        site.shiftEndOn(day).add(Duration(minutes: stayMinutes) + jitter(6)),
      );
    }

    // The last six calendar days, working days only (Monday–Friday).
    final days = [
      for (var back = 6; back >= 1; back--)
        today.subtract(Duration(days: back)),
    ].where((d) => d.weekday <= DateTime.friday).toList();

    DateTime? overtimeDayAsha;
    DateTime? overtimeDayRavi;
    DateTime? forgotDayJoseph;

    for (final (i, day) in days.indexed) {
      // Asha: Gate A, on time; one long day of overtime, left for approval.
      final aLong = i == days.length - 2;
      await normalDay(_asha, _gateA, day, stayMinutes: aLong ? 130 : 0);
      if (aLong) overtimeDayAsha = day;

      // Ravi: Gate B, late twice; one long day, already approved.
      final rLong = i == 1;
      await normalDay(
        _ravi,
        _gateB,
        day,
        lateMinutes: i.isEven ? 25 : 0,
        stayMinutes: rLong ? 120 : 0,
      );
      if (rLong) overtimeDayRavi = day;

      // Imran: starts at Gate A, moves to Gate B at midday without checking
      // out: the app closes Gate A automatically, minus travel.
      await punch(_imran, PunchType.checkIn, _gateA, t(day, 7).add(jitter(4)));
      await punch(_imran, PunchType.checkIn, _gateB, t(day, 12).add(jitter(4)));
      await punch(
        _imran,
        PunchType.checkOut,
        _gateB,
        t(day, 17).add(jitter(6)),
      );

      // Joseph: Gate A; forgets to check out once, closed at shift end on
      // his next check-in, and asks for a correction.
      final forgets = i == days.length - 3;
      await punch(
        _joseph,
        PunchType.checkIn,
        _gateA,
        t(day, 6, 50).add(jitter(4)),
      );
      if (forgets) {
        forgotDayJoseph = day;
      } else {
        await punch(
          _joseph,
          PunchType.checkOut,
          _gateA,
          t(day, 16, 5).add(jitter(6)),
        );
      }

      // Kumar: Gate B, a normal week; one punch with the phone clock off.
      await punch(
        _kumar,
        PunchType.checkIn,
        _gateB,
        t(day, 7, 55).add(jitter(4)),
        clockSuspect: i == 0,
      );
      await punch(
        _kumar,
        PunchType.checkOut,
        _gateB,
        t(day, 17).add(jitter(6)),
      );
    }

    // Today, only what has already happened by now.
    if (today.weekday <= DateTime.friday) {
      await punch(_asha, PunchType.checkIn, _gateA, t(today, 6, 58));
      await punch(_ravi, PunchType.checkIn, _gateB, t(today, 8, 22)); // late
      await punch(_imran, PunchType.checkIn, _gateA, t(today, 7, 3));
      await punch(_imran, PunchType.breakStart, _gateA, t(today, 12, 30));
      // Joseph is not in yet today; Kumar is on leave.
    }

    // Leave: Kumar away today and tomorrow (approved); Joseph has asked for
    // a sick day next week (waiting).
    final kumarLeave = await store.requestLeave(
      worker: _kumar,
      type: LeaveType.annual,
      from: today,
      to: today.add(const Duration(days: 1)),
      reason: 'Family visit',
    );
    await store.decideLeave(kumarLeave.id, approve: true);
    await store.requestLeave(
      worker: _joseph,
      type: LeaveType.sick,
      from: today.add(const Duration(days: 7)),
      to: today.add(const Duration(days: 7)),
      reason: 'Doctor appointment',
    );

    // Overtime: Ravi's long day approved, Asha's waiting.
    if (overtimeDayRavi != null) {
      await store.decideOvertime(_ravi.id, overtimeDayRavi, approve: true);
    }
    assert(
      overtimeDayAsha == null ||
          store.overtimeOn(_asha.id, overtimeDayAsha) > Duration.zero,
    );

    // Joseph asks to fix the day he forgot to check out.
    final forgot = forgotDayJoseph;
    if (forgot != null) {
      await store.requestCorrection(
        worker: _joseph,
        site: _gateA,
        type: PunchType.checkOut,
        at: t(forgot, 15, 40),
        reason: 'Forgot to check out, left at 15:40',
        now: at,
      );
    }
  });
}

/// Removes everything [loadDemoData] added, and nothing else.
Future<void> removeDemoData(AttendanceStore store) async {
  final ids = {
    for (final w in store.workers)
      if (w.id.startsWith(_demoPrefix)) w.id,
  };
  await store.removeRecordsOf(ids);
  await store.batch(() async {
    for (final id in ids) {
      await store.removeWorker(id);
    }
    for (final site in store.sitesOf(demoProjectId)) {
      await store.removeSite(site.id);
    }
    await store.removeProject(demoProjectId);
  });
}
