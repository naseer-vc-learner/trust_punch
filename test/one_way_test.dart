import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

const _a = Site(
  id: 'a',
  name: 'Gate A',
  latitude: 25.2000,
  longitude: 55.2700,
  projectId: 'p1',
  shiftStartMinutes: 7 * 60,
  shiftEndMinutes: 16 * 60,
);
const _b = Site(
  id: 'b',
  name: 'Gate B',
  latitude: 25.2450,
  longitude: 55.2700,
  projectId: 'p1',
);
const _asha = Worker(
  id: 'w1',
  employeeId: 'E1',
  name: 'Asha',
  embeddings: [],
  projectId: 'p1',
);

final _day = DateTime(2027, 3, 2);
DateTime _at(int h, [int m = 0]) => _day.add(Duration(hours: h, minutes: m));

void main() {
  late AttendanceStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await AttendanceStore.load();
    await store.addSite(_a);
    await store.addSite(_b);
    await store.addWorker(_asha);
  });

  /// Punches as the app does, the given way.
  Future<void> punch(PunchType type, DateTime at, PunchVia via,
      {Site site = _a}) async {
    final plan = store.planAt(_asha.id, site, now: at);
    expect(plan.actions, contains(type));
    await store.recordPunch(
      plan,
      Punch(
        type: type,
        at: at,
        workerId: _asha.id,
        employeeId: _asha.employeeId,
        workerName: _asha.name,
        siteId: site.id,
        siteName: site.name,
        latitude: site.latitude,
        longitude: site.longitude,
        distanceMeters: 5,
        via: via,
      ),
    );
  }

  bool allowed(PunchVia via, DateTime at) =>
      store.viaAllowed(_asha.id, via, now: at);

  test('checked in at the gate: not on their own phone until checked out',
      () async {
    await punch(PunchType.checkIn, _at(7), PunchVia.gate);
    expect(store.openSessionVia(_asha.id, now: _at(9)), PunchVia.gate);
    expect(allowed(PunchVia.ownPhone, _at(9)), isFalse);
    expect(allowed(PunchVia.gate, _at(9)), isTrue);

    await punch(PunchType.checkOut, _at(16), PunchVia.gate);
    expect(allowed(PunchVia.ownPhone, _at(17)), isTrue);
  });

  test('and the other way round', () async {
    await punch(PunchType.checkIn, _at(7), PunchVia.ownPhone);
    expect(allowed(PunchVia.gate, _at(12)), isFalse);
  });

  test('the store itself refuses, whatever screen asks', () async {
    await punch(PunchType.checkIn, _at(7), PunchVia.gate);
    expect(
      () => punch(PunchType.breakStart, _at(12), PunchVia.ownPhone),
      throwsStateError,
    );
    expect(store.punchesFor(_asha.id, _day), hasLength(1));
  });

  test('a break keeps the session going the same way', () async {
    await punch(PunchType.checkIn, _at(7), PunchVia.gate);
    await punch(PunchType.breakStart, _at(12), PunchVia.gate);
    expect(allowed(PunchVia.ownPhone, _at(12, 10)), isFalse);
    await punch(PunchType.breakEnd, _at(12, 30), PunchVia.gate);
    expect(allowed(PunchVia.ownPhone, _at(13)), isFalse);
  });

  test("moving location: the app's automatic check-out does not end it",
      () async {
    await punch(PunchType.checkIn, _at(7), PunchVia.gate);
    await punch(PunchType.checkIn, _at(12), PunchVia.gate, site: _b);
    expect(store.punchesFor(_asha.id, _day).any((p) => p.auto), isTrue);
    expect(allowed(PunchVia.ownPhone, _at(13)), isFalse);
  });

  test('a session left open yesterday does not lock anyone out today',
      () async {
    await punch(PunchType.checkIn, _at(7), PunchVia.gate);
    final tomorrow = _at(7).add(const Duration(days: 1));
    expect(allowed(PunchVia.ownPhone, tomorrow), isTrue);
    await punch(PunchType.checkIn, tomorrow, PunchVia.ownPhone);
    expect(store.openSessionVia(_asha.id, now: tomorrow), PunchVia.ownPhone);
  });

  test('automatic and corrected punches never lock', () async {
    await store.add(Punch(
      type: PunchType.checkIn,
      at: _at(7),
      workerId: _asha.id,
      employeeId: _asha.employeeId,
      workerName: _asha.name,
      siteId: _a.id,
      siteName: _a.name,
      latitude: _a.latitude,
      longitude: _a.longitude,
      distanceMeters: 0,
      corrected: true,
    ));
    expect(store.openSessionVia(_asha.id, now: _at(9)), isNull);
    expect(allowed(PunchVia.ownPhone, _at(9)), isTrue);
  });

  test('the way is remembered across a restart', () async {
    await punch(PunchType.checkIn, _at(7), PunchVia.gate);
    final again = await AttendanceStore.load();
    expect(again.lastPunchFor(_asha.id)!.via, PunchVia.gate);
    expect(again.viaAllowed(_asha.id, PunchVia.ownPhone, now: _at(9)), isFalse);
  });
}
