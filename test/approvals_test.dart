import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/models/requests.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

const _a = Site(
  id: 'A',
  name: 'Gate A',
  latitude: 25.2000,
  longitude: 55.2700,
  projectId: 'p1',
  shiftStartMinutes: 7 * 60,
  shiftEndMinutes: 16 * 60,
);
const _other = Site(
  id: 'X',
  name: 'Other',
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
);

final _day = DateTime(2027, 3, 2);
DateTime _at(int h, [int m = 0]) => _day.add(Duration(hours: h, minutes: m));

void main() {
  late AttendanceStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await AttendanceStore.load();
    await store.addSite(_a);
    await store.addSite(_other);
    await store.addWorker(_asha);
  });

  Future<void> punch(PunchType type, DateTime at, {Site site = _a}) async {
    final plan = store.planAt(_asha.id, site, now: at);
    expect(plan.actions, contains(type), reason: '$type at $at');
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
        distanceMeters: 0,
      ),
    );
  }

  group('overtime', () {
    test('a finished 10-hour day waits for approval, paid 8 h until then',
        () async {
      await punch(PunchType.checkIn, _at(7));
      await punch(PunchType.checkOut, _at(17));

      expect(store.overtimeOn(_asha.id, _day), const Duration(hours: 2));
      expect(store.overtimeStatus(_asha.id, _day), RequestStatus.pending);
      expect(store.pendingOvertime.single.$2, _day);
      expect(store.payableOn(_asha.id, _day), const Duration(hours: 8));
    });

    test('approved overtime is paid; the decision cannot be flipped',
        () async {
      await punch(PunchType.checkIn, _at(7));
      await punch(PunchType.checkOut, _at(17));
      await store.decideOvertime(_asha.id, _day, approve: true);
      await store.decideOvertime(_asha.id, _day, approve: false);

      expect(store.overtimeStatus(_asha.id, _day), RequestStatus.approved);
      expect(store.payableOn(_asha.id, _day), const Duration(hours: 10));
      expect(store.pendingOvertimeCount, 0);
    });

    test('rejected overtime is not paid', () async {
      await punch(PunchType.checkIn, _at(7));
      await punch(PunchType.checkOut, _at(17));
      await store.decideOvertime(_asha.id, _day, approve: false);
      expect(store.payableOn(_asha.id, _day), const Duration(hours: 8));
    });

    test('decisions survive a restart', () async {
      await punch(PunchType.checkIn, _at(7));
      await punch(PunchType.checkOut, _at(17));
      await store.decideOvertime(_asha.id, _day, approve: true);
      final reloaded = await AttendanceStore.load();
      expect(reloaded.overtimeStatus(_asha.id, _day), RequestStatus.approved);
    });
  });

  group('corrections', () {
    Future<CorrectionRequest> ask(PunchType type, DateTime at) =>
        store.requestCorrection(
          worker: _asha,
          site: _a,
          type: type,
          at: at,
          reason: 'Forgot',
          now: _at(48),
        );

    test('an approved check-out replaces the automatic one', () async {
      await punch(PunchType.checkIn, _at(7));
      // Next day she checks in; yesterday is closed at the 16:00 shift end.
      await punch(PunchType.checkIn, _at(24 + 7));
      expect(store.workedOn(_asha.id, _day), const Duration(hours: 9));

      final request = await ask(PunchType.checkOut, _at(15, 30));
      await store.decideCorrection(request.id, approve: true);

      final day = store.punchesFor(_asha.id, _day);
      expect(day.map((p) => p.type), [PunchType.checkIn, PunchType.checkOut]);
      expect(day.last.corrected, isTrue);
      expect(day.last.auto, isFalse);
      expect(store.workedOn(_asha.id, _day), const Duration(hours: 8, minutes: 30));

      final decided = store.corrections.single;
      expect(decided.status, RequestStatus.approved);
      expect(decided.replacedAt, _at(16));
      expect(decided.replacedAuto, isTrue);
      expect(store.flagsFor(_asha.id, _day).corrected, isTrue);
    });

    test('an approved check-in moves a late start earlier', () async {
      await punch(PunchType.checkIn, _at(10));
      await punch(PunchType.checkOut, _at(17));
      expect(store.flagsFor(_asha.id, _day).late, isTrue);

      final request = await ask(PunchType.checkIn, _at(7));
      await store.decideCorrection(request.id, approve: true);

      final day = store.punchesFor(_asha.id, _day);
      expect(day.first.at, _at(7));
      expect(day.length, 2);
      expect(store.workedOn(_asha.id, _day), const Duration(hours: 10));
      expect(store.flagsFor(_asha.id, _day).late, isFalse);
    });

    test('a correction that does not fit is refused and stays pending',
        () async {
      await punch(PunchType.checkIn, _at(7));
      await punch(PunchType.checkOut, _at(12));
      // A check-out before any check-in that day cannot be placed.
      final request = await ask(PunchType.checkOut, _at(6));
      expect(
        () => store.decideCorrection(request.id, approve: true),
        throwsStateError,
      );
      expect(store.corrections.single.status, RequestStatus.pending);
      expect(store.punchesFor(_asha.id, _day), hasLength(2));
    });

    test('a rejected request changes nothing', () async {
      await punch(PunchType.checkIn, _at(10));
      final request = await ask(PunchType.checkIn, _at(7));
      await store.decideCorrection(request.id, approve: false);
      expect(store.corrections.single.status, RequestStatus.rejected);
      expect(store.punchesFor(_asha.id, _day).single.at, _at(10));
    });

    test('bad requests are refused up front', () async {
      Future<void> bad({
        PunchType type = PunchType.checkOut,
        DateTime? at,
        String reason = 'x',
        Site site = _a,
      }) =>
          store.requestCorrection(
            worker: _asha,
            site: site,
            type: type,
            at: at ?? _at(10),
            reason: reason,
            now: _at(12),
          );
      expect(() => bad(at: _at(13)), throwsArgumentError); // future
      expect(() => bad(reason: '  '), throwsArgumentError);
      expect(() => bad(site: _other), throwsArgumentError);
      expect(() => bad(type: PunchType.breakStart), throwsArgumentError);
      expect(store.pendingCorrectionCount, 0);
    });
  });

  test('the clock check allows two minutes, then refuses', () async {
    await punch(PunchType.checkIn, _at(12));
    expect(store.clockLooksWrong(_at(11, 59)), isFalse);
    expect(store.clockLooksWrong(_at(11, 50)), isTrue);
    expect(store.clockLooksWrong(_at(12, 30)), isFalse);
  });

  test('worker day: times, lateness, break and hours', () async {
    await punch(PunchType.checkIn, _at(7, 25)); // shift 07:00 → 25 min late
    await punch(PunchType.breakStart, _at(12));
    await punch(PunchType.breakEnd, _at(12, 45));
    await punch(PunchType.checkOut, _at(16, 25));

    final day = store.workerDay(_asha.id, _day);
    expect(day.firstIn, _at(7, 25));
    expect(day.lastOut, _at(16, 25));
    expect(day.lateBy, const Duration(minutes: 25));
    expect(day.breaks, const Duration(minutes: 45));
    expect(day.worked, const Duration(hours: 8, minutes: 15));
    expect(day.overtimeStatus, RequestStatus.pending);
  });

  test('the day sequence check', () {
    Punch p(PunchType type, int h) => Punch(
          type: type,
          at: _at(h),
          workerId: 'w',
          employeeId: '',
          workerName: '',
          siteId: 'A',
          siteName: '',
          latitude: 0,
          longitude: 0,
          distanceMeters: 0,
        );
    expect(
      AttendanceStore.validDay([
        p(PunchType.checkIn, 7),
        p(PunchType.breakStart, 10),
        p(PunchType.checkOut, 11), // closed from a break: allowed
        p(PunchType.checkIn, 12),
      ]),
      isTrue,
    );
    expect(
      AttendanceStore.validDay(
          [p(PunchType.checkIn, 7), p(PunchType.checkIn, 8)]),
      isFalse,
    );
    expect(AttendanceStore.validDay([p(PunchType.checkOut, 7)]), isFalse);
  });
}
