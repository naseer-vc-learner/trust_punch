import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

Punch _punch(PunchType type, DateTime at, {String site = 'Gate A'}) => Punch(
      type: type,
      at: at,
      workerId: 'w1',
      employeeId: 'E1',
      workerName: 'Asha',
      siteId: site,
      siteName: site,
      latitude: 0,
      longitude: 0,
      distanceMeters: 0,
    );

void main() {
  late AttendanceStore store;
  final now = DateTime.now();
  final yesterday = DateTime(now.year, now.month, now.day - 1);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await AttendanceStore.load();
  });

  test('a finished 4-hour day is short', () async {
    await store.add(_punch(PunchType.checkIn, yesterday.add(const Duration(hours: 9))));
    await store.add(_punch(PunchType.checkOut, yesterday.add(const Duration(hours: 13))));
    expect(store.flagsFor('w1', yesterday).short, isTrue);
  });

  test('a past short day stays short while the worker is clocked in today',
      () async {
    await store.add(_punch(PunchType.checkIn, yesterday.add(const Duration(hours: 9))));
    await store.add(_punch(PunchType.checkOut, yesterday.add(const Duration(hours: 13))));
    await store.add(_punch(PunchType.checkIn, now.subtract(const Duration(minutes: 5))));
    expect(store.flagsFor('w1', yesterday).short, isTrue);
  });

  test('a full 8-hour day is not short', () async {
    await store.add(_punch(PunchType.checkIn, yesterday.add(const Duration(hours: 9))));
    await store.add(_punch(PunchType.checkOut, yesterday.add(const Duration(hours: 17))));
    expect(store.flagsFor('w1', yesterday).short, isFalse);
  });

  test('today is not short while the session is still open', () async {
    await store.add(_punch(PunchType.checkIn, now.subtract(const Duration(minutes: 5))));
    expect(store.flagsFor('w1', now).short, isFalse);
  });

  test('hours are split by site when a worker moves', () async {
    final day = yesterday;
    await store.add(_punch(PunchType.checkIn, day.add(const Duration(hours: 8))));
    await store.add(_punch(PunchType.checkOut, day.add(const Duration(hours: 11))));
    await store.add(_punch(PunchType.checkIn, day.add(const Duration(hours: 12)), site: 'Gate B'));
    await store.add(_punch(PunchType.checkOut, day.add(const Duration(hours: 17)), site: 'Gate B'));
    expect(store.workedBySiteOn('w1', day), {
      'Gate A': const Duration(hours: 3),
      'Gate B': const Duration(hours: 5),
    });
  });
}
