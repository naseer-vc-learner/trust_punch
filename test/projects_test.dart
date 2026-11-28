import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/models/project.dart';
import 'package:trust_punch/src/store/attendance_database.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

// Two locations about 5 km apart: ~10 minutes at the assumed 30 km/h.
const _a = Site(
  id: 'A',
  name: 'Gate A',
  latitude: 25.2000,
  longitude: 55.2700,
  projectId: 'p1',
  shiftStartMinutes: 7 * 60,
  shiftEndMinutes: 16 * 60,
);
const _b = Site(
  id: 'B',
  name: 'Gate B',
  latitude: 25.2450,
  longitude: 55.2700,
  projectId: 'p1',
);
const _other = Site(
  id: 'X',
  name: 'Other project gate',
  latitude: 25.3,
  longitude: 55.3,
  projectId: 'p2',
);
const _asha = Worker(
  id: 'w1',
  employeeId: 'E1',
  name: 'Asha',
  embeddings: [],
  projectId: 'p1',
  role: 'Mason',
  job: 'Block A foundation',
);

final _day = DateTime(2027, 3, 2);
DateTime _at(int h, [int m = 0]) => _day.add(Duration(hours: h, minutes: m));

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
    await store.addSite(_a);
    await store.addSite(_b);
    await store.addSite(_other);
    await store.addWorker(_asha);
  });

  /// Punches as the app does: plan at that moment, then record.
  Future<PunchPlan> punch(PunchType type, Site site, DateTime at) async {
    final plan = store.planAt(_asha.id, site, now: at);
    expect(plan.actions, contains(type));
    await store.recordPunch(plan, _punch(type, site, at));
    return plan;
  }

  test('travel estimate is distance at 30 km/h', () {
    final travel = AttendanceStore.travelBetween(_a, _b);
    expect(travel.inSeconds, closeTo(600, 5));
  });

  group('what may happen next', () {
    test('nothing open: check in', () {
      final plan = store.planAt(_asha.id, _a, now: _at(7));
      expect(plan.actions, [PunchType.checkIn]);
      expect(plan.autoClose, isNull);
    });

    test('open here: check out or break, then end the break', () async {
      await punch(PunchType.checkIn, _a, _at(7));
      expect(store.planAt(_asha.id, _a, now: _at(10)).actions,
          [PunchType.checkOut, PunchType.breakStart]);
      await punch(PunchType.breakStart, _a, _at(12));
      expect(store.planAt(_asha.id, _a, now: _at(12, 30)).actions,
          [PunchType.breakEnd]);
    });
  });

  group('moving to another location without checking out', () {
    test('closes the first at check-in minus travel, marked auto', () async {
      await punch(PunchType.checkIn, _a, _at(7));
      final plan = await punch(PunchType.checkIn, _b, _at(12));

      final auto = plan.autoClose!;
      expect(auto.auto, isTrue);
      expect(auto.type, PunchType.checkOut);
      expect(auto.siteId, 'A');
      expect(_at(12).difference(auto.at).inSeconds, closeTo(600, 5));
      expect(store.statusOf(_asha.id), WorkerStatus.working);
    });

    test('hours by site, travel and total add up', () async {
      await punch(PunchType.checkIn, _a, _at(7));
      await punch(PunchType.checkIn, _b, _at(12));
      await punch(PunchType.checkOut, _b, _at(17));

      final bySite = store.workedBySiteOn(_asha.id, _day);
      expect(bySite['Gate A']!.inMinutes, closeTo(290, 1)); // 07:00–11:50
      expect(bySite['Gate B'], const Duration(hours: 5)); // 12:00–17:00
      expect(store.travelOn(_asha.id, _day).inMinutes, closeTo(10, 1));
      expect(store.workedOn(_asha.id, _day).inMinutes, closeTo(590, 1));
      expect(store.flagsFor(_asha.id, _day).autoCheckout, isTrue);
    });

    test('never closes before the last punch there', () async {
      await punch(PunchType.checkIn, _a, _at(7));
      // Two minutes later at B, with ~10 minutes of travel: impossible, so
      // the close is held at the check-in, not pushed before it.
      final plan = await punch(PunchType.checkIn, _b, _at(7, 2));
      expect(plan.autoClose!.at, _at(7));
    });

    test('a break left open at A ends as break, not work', () async {
      await punch(PunchType.checkIn, _a, _at(7));
      await punch(PunchType.breakStart, _a, _at(11));
      await punch(PunchType.checkIn, _b, _at(12));
      await punch(PunchType.checkOut, _b, _at(13));
      expect(store.workedBySiteOn(_asha.id, _day)['Gate A'],
          const Duration(hours: 4));
      expect(store.breakOn(_asha.id, _day).inMinutes, closeTo(50, 1));
    });

    test('a proper check-out still shows the gap as travel', () async {
      await punch(PunchType.checkIn, _a, _at(7));
      await punch(PunchType.checkOut, _a, _at(11));
      final plan = await punch(PunchType.checkIn, _b, _at(11, 40));
      expect(plan.autoClose, isNull);
      expect(store.travelOn(_asha.id, _day), const Duration(minutes: 40));
      expect(store.flagsFor(_asha.id, _day).autoCheckout, isFalse);
    });
  });

  test('a session left open on an earlier day closes at its shift end',
      () async {
    await punch(PunchType.checkIn, _a, _at(7));
    final nextDay = _day.add(const Duration(days: 1, hours: 7));
    final plan = store.planAt(_asha.id, _a, now: nextDay);
    expect(plan.actions, [PunchType.checkIn]);
    expect(plan.autoClose!.at, _at(16)); // Gate A shift ends 16:00
    await store.recordPunch(plan, _punch(PunchType.checkIn, _a, nextDay));
    expect(store.workedOn(_asha.id, _day), const Duration(hours: 9));
  });

  test('late is judged against the first location\'s own shift', () async {
    await punch(PunchType.checkIn, _a, _at(7, 20)); // Gate A starts 07:00
    expect(store.flagsFor(_asha.id, _day).late, isTrue);

    final next = _day.add(const Duration(days: 1));
    final plan = store.planAt(_asha.id, _b, now: next.add(const Duration(hours: 9, minutes: 5)));
    await store.recordPunch(plan,
        _punch(PunchType.checkIn, _b, next.add(const Duration(hours: 9, minutes: 5))));
    expect(store.flagsFor(_asha.id, next).late, isFalse); // Gate B starts 09:00
  });

  test('a worker can only punch at their own project\'s locations', () {
    expect(store.canPunchAt(_asha, _a), isTrue);
    expect(store.canPunchAt(_asha, _other), isFalse);
    expect(store.canPunchAt(_asha.copyWith(projectId: ''), _a), isFalse);
  });

  test('a project with locations or workers cannot be deleted', () async {
    final p = await store.addProject('Empty');
    expect(await store.removeProject('p1'), isFalse);
    expect(await store.removeProject(p.id), isTrue);
  });

  test('a shift must end after it starts', () async {
    expect(() => store.setShift('A', 600, 540), throwsArgumentError);
    await store.setShift('A', 6 * 60, 14 * 60);
    expect(store.siteById('A')!.shiftStartMinutes, 360);
  });

  test('old sites and workers move into the General project', () async {
    // An install from before projects: everything still in preferences,
    // nothing in the database yet.
    AttendanceDatabase.debugUse(AttendanceDatabase.inMemory());
    SharedPreferences.setMockInitialValues({
      'flutter.sites': [
        jsonEncode({'id': 's1', 'name': 'Old gate', 'lat': 1.0, 'lng': 2.0}),
      ],
      'flutter.workers': [
        jsonEncode({
          'id': 'old',
          'employeeId': '',
          'name': 'Old worker',
          'embeddings': [],
        }),
      ],
    });
    final loaded = await AttendanceStore.load();
    expect(loaded.projectById(generalProjectId)?.name, 'General');
    expect(loaded.siteById('s1')!.projectId, generalProjectId);
    expect(loaded.siteById('s1')!.shiftStartMinutes, Site.defaultShiftStart);
    expect(loaded.workers.single.projectId, generalProjectId);

    // Saved back: a second load needs no migration and finds the same.
    final again = await AttendanceStore.load();
    expect(again.projects, hasLength(1));
    expect(again.workers.single.projectId, generalProjectId);
  });
}
