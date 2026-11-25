import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/models/leave.dart';
import 'package:trust_punch/src/services/supervisor_lock.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

const _asha = Worker(id: 'w1', employeeId: 'E1', name: 'Asha', embeddings: []);
const _ravi = Worker(id: 'w2', employeeId: 'E2', name: 'Ravi', embeddings: []);

Punch _punch(Worker w, PunchType type, DateTime at) => Punch(
      type: type,
      at: at,
      workerId: w.id,
      employeeId: w.employeeId,
      workerName: w.name,
      siteId: 's1',
      siteName: 'Gate A',
      latitude: 0,
      longitude: 0,
      distanceMeters: 0,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('remembered role', () {
    test('starts at the picker', () async {
      final store = await AttendanceStore.load();
      expect(store.lastRole, isNull);
    });

    test('worker and kiosk survive a restart', () async {
      for (final role in [AppRole.worker, AppRole.kiosk]) {
        final store = await AttendanceStore.load();
        await store.setLastRole(role);
        expect((await AttendanceStore.load()).lastRole, role);
      }
    });

    test('supervisor is never remembered', () async {
      final store = await AttendanceStore.load();
      await store.setLastRole(AppRole.kiosk);
      await store.setLastRole(AppRole.supervisor);
      expect(store.lastRole, isNull);
      expect((await AttendanceStore.load()).lastRole, isNull);
    });

    test('an old saved supervisor value is ignored', () async {
      SharedPreferences.setMockInitialValues({'flutter.role': 'supervisor'});
      expect((await AttendanceStore.load()).lastRole, isNull);
    });
  });

  group('supervisor session', () {
    test('starts closed, opens and closes', () async {
      final lock = await SupervisorLock.load();
      expect(lock.sessionActive, isFalse);
      lock.beginSession();
      expect(lock.sessionActive, isTrue);
      lock.endSession();
      expect(lock.sessionActive, isFalse);
    });

    test('a restart always starts closed', () async {
      (await SupervisorLock.load()).beginSession();
      expect((await SupervisorLock.load()).sessionActive, isFalse);
    });
  });

  group('one worker\'s own view', () {
    final day = DateTime(2027, 3, 2);

    test('month totals, punches and leave narrow to that worker', () async {
      final store = await AttendanceStore.load();
      await store.addWorker(_asha);
      await store.addWorker(_ravi);
      await store.add(_punch(_asha, PunchType.checkIn, day.add(const Duration(hours: 9))));
      await store.add(_punch(_asha, PunchType.checkOut, day.add(const Duration(hours: 12))));
      await store.add(_punch(_ravi, PunchType.checkIn, day.add(const Duration(hours: 9))));
      await store.add(_punch(_ravi, PunchType.checkOut, day.add(const Duration(hours: 17))));
      final leave = await store.requestLeave(
        worker: _ravi,
        type: LeaveType.annual,
        from: DateTime(2027, 3, 4),
        to: DateTime(2027, 3, 5),
        reason: '',
      );
      await store.decideLeave(leave.id, approve: true);

      expect(store.monthTotal(2027, 3), const Duration(hours: 11));
      expect(store.monthTotal(2027, 3, workerId: 'w1'), const Duration(hours: 3));
      expect(store.punchesOn(day, workerId: 'w1'), hasLength(2));
      expect(store.leaveDaysIn(2027, 3), {4, 5});
      expect(store.leaveDaysIn(2027, 3, workerId: 'w1'), isEmpty);
      expect(store.pendingLeaveCount, 0);
    });
  });
}
