import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

// One gate used by two projects, each with its own location record and
// shift; and a second gate of the day project elsewhere.
const _day = Site(
  id: 'day',
  name: 'Gate A',
  latitude: 25.2048,
  longitude: 55.2708,
  projectId: 'pDay',
  shiftStartMinutes: 7 * 60,
  shiftEndMinutes: 16 * 60,
);
const _evening = Site(
  id: 'evening',
  name: 'Gate A',
  latitude: 25.2048,
  longitude: 55.2709, // ~10 m away: the same place
  projectId: 'pEve',
  shiftStartMinutes: 16 * 60,
  shiftEndMinutes: 23 * 60,
);
const _overlap = Site(
  id: 'overlap',
  name: 'Gate A',
  latitude: 25.2048,
  longitude: 55.2708,
  projectId: 'pMid',
  shiftStartMinutes: 12 * 60,
  shiftEndMinutes: 20 * 60,
);

const _asha = Worker(
  id: 'w1',
  employeeId: 'E1',
  name: 'Asha',
  embeddings: [],
  projectId: 'pDay',
  role: 'Mason',
  job: 'Foundation',
  otherProjects: [
    ProjectAssignment(projectId: 'pEve', role: 'Supervisor', job: 'Pour'),
  ],
);

final _date = DateTime(2027, 3, 2);
DateTime _at(int h, [int m = 0]) => _date.add(Duration(hours: h, minutes: m));

Punch _punch(PunchType type, Site site, DateTime at) => Punch(
      type: type,
      at: at,
      workerId: _asha.id,
      employeeId: _asha.employeeId,
      workerName: _asha.name,
      siteId: site.id,
      siteName: site.name,
      latitude: site.latitude,
      longitude: site.longitude,
      distanceMeters: 0,
    );

void main() {
  late AttendanceStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await AttendanceStore.load();
    for (final p in ['pDay', 'pEve', 'pMid']) {
      await store.addProject(p, id: p);
    }
    for (final s in [_day, _evening, _overlap]) {
      await store.addSite(s);
    }
    await store.addWorker(_asha);
  });

  /// The location the app would pick at [at], then the punch there.
  Future<Site> punchHere(PunchType type, DateTime at,
      {List<Site> here = const [_day, _evening]}) async {
    final site = store.siteFor(store.workers.single, here, now: at).site!;
    final plan = store.planAt(_asha.id, site, now: at);
    expect(plan.actions, contains(type));
    await store.recordPunch(plan, _punch(type, site, at));
    return site;
  }

  group('a worker on several projects', () {
    test('is on each, with its own role and job', () {
      final w = store.workers.single;
      expect(store.workersOf('pDay'), [w]);
      expect(store.workersOf('pEve'), [w]);
      expect(w.assignmentIn('pEve')!.role, 'Supervisor');
      expect(store.canPunchAt(w, _evening), isTrue);
      expect(store.canPunchAt(w, _overlap), isFalse);
    });

    test('joining another project adds it, keeping the first', () async {
      await store.assignWorker(_asha.id,
          projectId: 'pMid', role: 'Helper', job: 'Tiling');
      final w = store.workers.single;
      expect(w.assignments.map((a) => a.projectId), ['pDay', 'pEve', 'pMid']);
      expect(w.assignmentIn('pDay')!.role, 'Mason');

      // Changing the role on one project leaves the others alone.
      await store.assignWorker(_asha.id,
          projectId: 'pEve', role: 'Foreman', job: 'Pour');
      expect(store.workers.single.assignmentIn('pEve')!.role, 'Foreman');
      expect(store.workers.single.assignments, hasLength(3));
    });

    test('can leave one project, never the last', () async {
      expect(await store.unassignWorker(_asha.id, 'pDay'), isTrue);
      final w = store.workers.single;
      expect(w.projectId, 'pEve', reason: 'the next project moves up');
      expect(w.role, 'Supervisor');
      expect(await store.unassignWorker(_asha.id, 'pEve'), isFalse);
      expect(store.workers.single.isOn('pEve'), isTrue);
    });

    test('survives a restart', () async {
      final again = await AttendanceStore.load();
      expect(again.workers.single.assignmentIn('pEve')!.job, 'Pour');
    });
  });

  group('the shift picks the project at a shared place', () {
    test('morning check-in goes to the day project', () async {
      expect((await punchHere(PunchType.checkIn, _at(6, 50))).id, 'day');
    });

    test('evening check-in goes to the evening project', () async {
      expect((await punchHere(PunchType.checkIn, _at(16, 5))).id, 'evening');
    });

    test('early by up to 30 minutes still counts for that shift', () {
      final choice =
          store.siteFor(_asha, const [_day, _evening], now: _at(15, 40));
      // 15:40 is inside the day shift and within 30 min of the evening
      // one: both running, so the worker is asked.
      expect(choice.options.map((s) => s.id), ['day', 'evening']);
    });

    test('outside every shift, the nearest one in time', () {
      expect(store.siteFor(_asha, const [_day, _evening], now: _at(5)).site!.id,
          'day');
      expect(
          store.siteFor(_asha, const [_day, _evening], now: _at(23, 30))
              .site!
              .id,
          'evening');
    });

    test('a location of a project they are not on is never picked', () {
      final choice =
          store.siteFor(_asha, const [_overlap, _evening], now: _at(13));
      expect(choice.site!.id, 'evening');
      expect(store.siteFor(_asha, const [_overlap], now: _at(13)).site, isNull);
    });

    test('on the clock and within the shift: stays where they are', () async {
      await punchHere(PunchType.checkIn, _at(7));
      expect(store.siteFor(_asha, const [_day, _evening], now: _at(15, 50))
          .site!
          .id, 'day', reason: 'no question while their own shift runs');
    });
  });

  group('staying on past one shift into the other', () {
    test('splits the hours at the shift end', () async {
      await punchHere(PunchType.checkIn, _at(7));
      final site = await punchHere(PunchType.checkOut, _at(20));
      expect(site.id, 'evening');

      final punches = store.punchesFor(_asha.id, _date);
      expect(punches.map((p) => (p.type, p.siteId, p.at.hour, p.auto)), [
        (PunchType.checkIn, 'day', 7, false),
        (PunchType.checkOut, 'day', 16, true),
        (PunchType.checkIn, 'evening', 16, true),
        (PunchType.checkOut, 'evening', 20, false),
      ]);
      expect(AttendanceStore.validDay(punches), isTrue);
      expect(store.workedOnProject(_asha.id, 'pDay', _date),
          const Duration(hours: 9));
      expect(store.workedOnProject(_asha.id, 'pEve', _date),
          const Duration(hours: 4));
      expect(store.travelOn(_asha.id, _date), Duration.zero);
      expect(store.flagsFor(_asha.id, _date).autoCheckout, isTrue);
    });

    test('overtime is the whole day, across both projects', () async {
      await punchHere(PunchType.checkIn, _at(7));
      await punchHere(PunchType.checkOut, _at(20));
      expect(store.overtimeOn(_asha.id, _date), const Duration(hours: 5));
    });

    test('a break past the shift end splits too, then finishes', () async {
      await punchHere(PunchType.checkIn, _at(7));
      expect((await punchHere(PunchType.breakStart, _at(17))).id, 'evening');
      await punchHere(PunchType.breakEnd, _at(17, 30));
      await punchHere(PunchType.checkOut, _at(21));
      expect(store.workedOnProject(_asha.id, 'pEve', _date),
          const Duration(hours: 4, minutes: 30));
    });

    test('no split when the next shift is not running yet', () async {
      const lateEvening = Site(
        id: 'late',
        name: 'Gate A',
        latitude: 25.2048,
        longitude: 55.2708,
        projectId: 'pEve',
        shiftStartMinutes: 19 * 60,
        shiftEndMinutes: 23 * 60,
      );
      await store.addSite(lateEvening);
      await punchHere(PunchType.checkIn, _at(7),
          here: const [_day, lateEvening]);
      // 16:30: day shift over, evening not started (nor within 30 min).
      final site = await punchHere(PunchType.checkOut, _at(16, 30),
          here: const [_day, lateEvening]);
      expect(site.id, 'day');
      expect(store.punchesFor(_asha.id, _date).any((p) => p.auto), isFalse);
    });
  });

  group('project dashboards', () {
    test('each counts only its own hours; the other shows where they are',
        () async {
      await punchHere(PunchType.checkIn, _at(7));
      final now = _at(18);
      // Still on the clock at 18:00: not yet split (that happens at the
      // next punch), so the day project shows them after its shift.
      final day = store.projectToday('pDay', now: now);
      expect(day.afterShift.map((e) => e.$1.name), ['Asha']);

      await punchHere(PunchType.breakStart, now);
      final dayAfter = store.projectToday('pDay', now: now);
      final evening = store.projectToday('pEve', now: now);
      expect(dayAfter.elsewhere.map((e) => e.$2.id), ['evening']);
      expect(dayAfter.notIn, isEmpty);
      expect(evening.locations.single.onBreak.map((w) => w.name), ['Asha']);
    });
  });
}
