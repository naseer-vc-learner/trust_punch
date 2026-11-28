import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/models/leave.dart';
import 'package:trust_punch/src/models/requests.dart';
import 'package:trust_punch/src/store/attendance_database.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

const _site = Site(
  id: 's1',
  name: 'Gate A',
  latitude: 25.2,
  longitude: 55.27,
  projectId: 'p1',
);
const _asha = Worker(
  id: 'w1',
  employeeId: 'E1',
  name: 'Asha',
  embeddings: [],
  projectId: 'p1',
);

Punch _punch(PunchType type, DateTime at, {String? photo}) => Punch(
      type: type,
      at: at,
      workerId: _asha.id,
      employeeId: _asha.employeeId,
      workerName: _asha.name,
      siteId: _site.id,
      siteName: _site.name,
      latitude: 25.2001,
      longitude: 55.2702,
      distanceMeters: 12.5,
      photo: photo,
    );

DateTime _daysAgo(int days, int hour) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - days, hour);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an older install is moved out of preferences once', () async {
    final day = _daysAgo(1, 0);
    SharedPreferences.setMockInitialValues({
      'flutter.language': 'hi',
      'flutter.sites': [jsonEncode(_site.toJson())],
      'flutter.workers': [jsonEncode(_asha.toJson())],
      'flutter.punches': [
        // Saved in arrival order; the import sorts.
        jsonEncode(_punch(PunchType.checkOut, _daysAgo(1, 19)).toJson()),
        jsonEncode(_punch(PunchType.checkIn, _daysAgo(1, 7)).toJson()),
      ],
      'flutter.leaves': [
        jsonEncode(LeaveRequest(
          id: 'l1',
          workerId: _asha.id,
          workerName: _asha.name,
          type: LeaveType.sick,
          from: day,
          to: day,
          reason: 'Fever',
          status: LeaveStatus.pending,
          requestedAt: day,
        ).toJson()),
      ],
      'flutter.overtime': [
        jsonEncode(OvertimeDecision(
          workerId: _asha.id,
          date: day,
          approved: true,
          minutes: 240,
          decidedAt: day,
        ).toJson()),
      ],
    });

    final store = await AttendanceStore.load();
    expect(store.workers.single.name, 'Asha');
    expect(store.punchesFor(_asha.id, day).map((p) => p.type),
        [PunchType.checkIn, PunchType.checkOut]);
    expect(store.pendingLeaveCount, 1);
    expect(store.overtimeStatus(_asha.id, day), RequestStatus.approved);
    expect(store.languageCode, 'hi', reason: 'settings stay in preferences');

    // Gone from preferences, so a second start cannot import twice.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('punches'), isNull);
    expect(prefs.getStringList('workers'), isNull);
    final again = await AttendanceStore.load();
    expect(again.workers, hasLength(1));
    expect(again.punchesFor(_asha.id, day), hasLength(2));
  });

  test('a punch survives a restart with every detail', () async {
    final store = await AttendanceStore.load();
    await store.addSite(_site);
    await store.addWorker(_asha);
    final at = DateTime.now().subtract(const Duration(minutes: 5));
    await store.recordPunch(
      store.planAt(_asha.id, _site, now: at),
      Punch(
        type: PunchType.checkIn,
        at: at,
        workerId: _asha.id,
        employeeId: _asha.employeeId,
        workerName: _asha.name,
        siteId: _site.id,
        siteName: _site.name,
        latitude: 25.2001,
        longitude: 55.2702,
        distanceMeters: 12.5,
        photo: 'w1_1.jpg',
        clockSuspect: true,
      ),
    );

    final p = (await AttendanceStore.load()).lastPunchFor(_asha.id)!;
    expect(p.at, at, reason: 'to the microsecond');
    expect(p.type, PunchType.checkIn);
    expect(p.employeeId, 'E1');
    expect(p.siteName, 'Gate A');
    expect(p.latitude, 25.2001);
    expect(p.distanceMeters, 12.5);
    expect(p.photo, 'w1_1.jpg');
    expect(p.clockSuspect, isTrue);
    expect(p.auto, isFalse);
    expect(p.corrected, isFalse);
  });

  group('memory window', () {
    late AttendanceStore store;
    final old = _daysAgo(punchMemoryDays + 30, 8);

    setUp(() async {
      store = await AttendanceStore.load();
      await store.addSite(_site);
      await store.addWorker(_asha);
      await store.add(_punch(PunchType.checkIn, old));
      await store.add(_punch(PunchType.checkOut, old.add(const Duration(hours: 9))));
      // Checked in long ago and never out: the newest punch is old too.
      await store.add(_punch(PunchType.checkIn, old.add(const Duration(days: 1))));
      store = await AttendanceStore.load();
    });

    test('old days stay in the database until their month is asked for',
        () async {
      expect(store.punchesFor(_asha.id, old), isEmpty);
      expect(store.monthTotals(old.year, old.month), isEmpty);

      expect(store.ensureMonthLoaded(old.year, old.month), isTrue);
      expect(store.punchesFor(_asha.id, old), hasLength(2));
      expect(store.monthTotals(old.year, old.month)[old.day],
          const Duration(hours: 9));
      expect(store.ensureMonthLoaded(old.year, old.month), isFalse,
          reason: 'already in memory');
    });

    test('a session left open long ago is still seen and closed', () {
      expect(store.statusOf(_asha.id), WorkerStatus.working);
      final plan = store.planAt(_asha.id, _site);
      expect(plan.autoClose, isNotNull);
      expect(plan.autoClose!.at.day, old.add(const Duration(days: 1)).day);
    });

    test('loading the month does not duplicate the newest punch', () {
      final open = old.add(const Duration(days: 1));
      store.ensureMonthLoaded(open.year, open.month);
      expect(store.punchesFor(_asha.id, open), hasLength(1));
    });
  });

  test('a replaced punch stays replaced after a restart', () async {
    var store = await AttendanceStore.load();
    await store.addSite(_site);
    await store.addWorker(_asha);
    final day = _daysAgo(2, 0);
    final plan = store.planAt(_asha.id, _site, now: _daysAgo(2, 7));
    await store.recordPunch(plan, _punch(PunchType.checkIn, _daysAgo(2, 7)));
    // Forgot to check out; the next check-in closes the day automatically.
    final next = _daysAgo(1, 7);
    final plan2 = store.planAt(_asha.id, _site, now: next);
    await store.recordPunch(plan2, _punch(PunchType.checkIn, next));
    expect(store.punchesFor(_asha.id, day).last.auto, isTrue);

    final request = await store.requestCorrection(
      worker: _asha,
      site: _site,
      type: PunchType.checkOut,
      at: _daysAgo(2, 15),
      reason: 'Forgot',
    );
    await store.decideCorrection(request.id, approve: true);

    store = await AttendanceStore.load();
    final punches = store.punchesFor(_asha.id, day);
    expect(punches, hasLength(2));
    expect(punches.last.corrected, isTrue);
    expect(punches.any((p) => p.auto), isFalse);
  });

  test('delete all stays deleted', () async {
    var store = await AttendanceStore.load();
    await store.add(_punch(PunchType.checkIn, _daysAgo(0, 7)));
    await store.clearPunches();
    store = await AttendanceStore.load();
    expect(store.lastPunchFor(_asha.id), isNull);
    expect(store.clockLooksWrong(DateTime(2000)), isFalse);
  });

  test('a batch is one transaction, saved at the end', () async {
    final db = AttendanceDatabase.inMemory();
    AttendanceDatabase.debugUse(db);
    final store = await AttendanceStore.load();
    var notified = 0;
    store.addListener(() => notified++);
    await store.batch(() async {
      await store.addSite(_site);
      await store.addWorker(_asha);
      await store.add(_punch(PunchType.checkIn, _daysAgo(0, 7)));
    });
    expect(notified, 1);
    expect(db.punchCount, 1);
    expect((await AttendanceStore.load()).workers, hasLength(1));
  });
}
