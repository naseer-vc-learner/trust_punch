import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/models/leave.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

const _asha = Worker(id: 'w1', employeeId: 'E1', name: 'Asha', embeddings: []);
const _ravi = Worker(id: 'w2', employeeId: 'E2', name: 'Ravi', embeddings: []);

void main() {
  late AttendanceStore store;
  final mon = DateTime(2027, 3, 1);
  final wed = DateTime(2027, 3, 3);
  final fri = DateTime(2027, 3, 5);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await AttendanceStore.load();
  });

  Future<LeaveRequest> ask(Worker w, DateTime from, DateTime to) =>
      store.requestLeave(
        worker: w,
        type: LeaveType.sick,
        from: from,
        to: to,
        reason: 'Fever',
      );

  test('a new request is pending and covers both end days', () async {
    final leave = await ask(_asha, mon, wed);
    expect(leave.status, LeaveStatus.pending);
    expect(leave.days, 3);
    expect(leave.covers(mon), isTrue);
    expect(leave.covers(wed.add(const Duration(hours: 23))), isTrue);
    expect(leave.covers(fri), isFalse);
  });

  test('only approved leave makes someone away', () async {
    final leave = await ask(_asha, mon, wed);
    expect(store.leaveOn('w1', mon), isNull);
    await store.decideLeave(leave.id, approve: true);
    expect(store.leaveOn('w1', mon)?.id, leave.id);
    expect(store.leavesOn(wed).map((l) => l.workerName), ['Asha']);
    expect(store.leaveDaysIn(2027, 3), {1, 2, 3});
  });

  test('rejected leave never counts', () async {
    final leave = await ask(_asha, mon, wed);
    await store.decideLeave(leave.id, approve: false);
    expect(store.leaveOn('w1', mon), isNull);
    expect(store.leaveDaysIn(2027, 3), isEmpty);
  });

  test('a decision cannot be flipped once made', () async {
    final leave = await ask(_asha, mon, wed);
    await store.decideLeave(leave.id, approve: false);
    await store.decideLeave(leave.id, approve: true);
    expect(store.leaves.single.status, LeaveStatus.rejected);
  });

  test('overlapping requests for the same worker are refused', () async {
    await ask(_asha, mon, wed);
    expect(store.hasOverlappingLeave('w1', wed, fri), isTrue);
    expect(() => ask(_asha, wed, fri), throwsStateError);
  });

  test('other workers and rejected requests do not block', () async {
    final first = await ask(_asha, mon, wed);
    expect(store.hasOverlappingLeave('w2', mon, wed), isFalse);
    await ask(_ravi, mon, wed);
    await store.decideLeave(first.id, approve: false);
    expect(store.hasOverlappingLeave('w1', mon, wed), isFalse);
  });

  test('leave cannot end before it starts', () async {
    expect(() => ask(_asha, wed, mon), throwsArgumentError);
  });

  test('leave survives an app restart', () async {
    final leave = await ask(_asha, mon, wed);
    await store.decideLeave(leave.id, approve: true);
    final reloaded = await AttendanceStore.load();
    final back = reloaded.leaves.single;
    expect(back.status, LeaveStatus.approved);
    expect(back.from, mon);
    expect(back.to, wed);
    expect(back.reason, 'Fever');
    expect(back.decidedAt, isNotNull);
  });
}
