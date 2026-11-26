import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/services/shift_reminders.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

const _a = Site(
  id: 'A',
  name: 'Gate A',
  latitude: 25.2,
  longitude: 55.27,
  projectId: 'p1',
  shiftStartMinutes: 7 * 60,
  shiftEndMinutes: 16 * 60,
);

void main() {
  final day = DateTime(2027, 3, 2);

  test('reminds at the location\'s shift end, if still ahead', () {
    expect(reminderTimeFor(_a, day.add(const Duration(hours: 7))),
        day.add(const Duration(hours: 16)));
    expect(reminderTimeFor(_a, day.add(const Duration(hours: 16, minutes: 5))),
        isNull);
  });

  test('a worker\'s reminder id is stable and differs between workers', () {
    expect(reminderIdFor('w1'), reminderIdFor('w1'));
    expect(reminderIdFor('w1'), isNot(reminderIdFor('w2')));
    expect(reminderIdFor('1732000000000000'), greaterThanOrEqualTo(0));
  });

  test('the dashboard lists who is still in after their shift', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await AttendanceStore.load();
    await store.addSite(_a);
    const asha = Worker(
      id: 'w1',
      employeeId: 'E1',
      name: 'Asha',
      embeddings: [],
      projectId: 'p1',
    );
    await store.addWorker(asha);
    final inAt = day.add(const Duration(hours: 7));
    await store.recordPunch(
      store.planAt(asha.id, _a, now: inAt),
      Punch(
        type: PunchType.checkIn,
        at: inAt,
        workerId: asha.id,
        employeeId: asha.employeeId,
        workerName: asha.name,
        siteId: _a.id,
        siteName: _a.name,
        latitude: _a.latitude,
        longitude: _a.longitude,
        distanceMeters: 0,
      ),
    );

    final during = store.projectToday('p1', now: day.add(const Duration(hours: 15)));
    expect(during.afterShift, isEmpty);
    final after = store.projectToday('p1', now: day.add(const Duration(hours: 17)));
    expect(after.afterShift.single.$1.name, 'Asha');
    expect(after.afterShift.single.$2.id, 'A');
  });
}
