import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/demo/demo_data.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/models/requests.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

// A Thursday afternoon: a full working week behind it.
final _now = DateTime(2027, 3, 4, 14);
final _today = DateTime(2027, 3, 4);

const _real = Worker(
  id: 'real-1',
  employeeId: 'R1',
  name: 'Real Person',
  embeddings: [],
  projectId: 'real-project',
);
const _realSite = Site(
  id: 'real-site',
  name: 'Real gate',
  latitude: 24.0,
  longitude: 54.0,
  projectId: 'real-project',
);

void main() {
  late AttendanceStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await AttendanceStore.load();
    await store.addProject('Real project', id: 'real-project');
    await store.addSite(_realSite);
    await store.addWorker(_real);
    final inAt = DateTime(2027, 3, 3, 8);
    await store.recordPunch(
      store.planAt(_real.id, _realSite, now: inAt),
      Punch(
        type: PunchType.checkIn,
        at: inAt,
        workerId: _real.id,
        employeeId: _real.employeeId,
        workerName: _real.name,
        siteId: _realSite.id,
        siteName: _realSite.name,
        latitude: 24,
        longitude: 54,
        distanceMeters: 0,
      ),
    );
    await loadDemoData(store, now: _now);
  });

  test('a project, two gates and five workers without face data', () {
    expect(hasDemoData(store), isTrue);
    expect(store.sitesOf(demoProjectId), hasLength(2));
    final workers = store.workersOf(demoProjectId);
    expect(workers, hasLength(5));
    expect(workers.every((w) => w.embeddings.isEmpty), isTrue);
  });

  test('the week tells the story the demo needs', () {
    final punches = [
      for (final w in store.workersOf(demoProjectId))
        for (var d = 0; d < 7; d++)
          ...store.punchesFor(w.id, _today.subtract(Duration(days: d))),
    ];
    expect(punches.any((p) => p.auto), isTrue, reason: 'auto check-out');
    expect(punches.any((p) => p.clockSuspect), isTrue, reason: 'clock flag');
    expect(punches.every((p) => !p.at.isAfter(_now)), isTrue,
        reason: 'nothing in the future');
    expect(store.pendingOvertime, isNotEmpty);
    expect(store.overtimeDecisions.where((d) => d.approved), isNotEmpty);
    expect(store.pendingCorrectionCount, 1);
    expect(store.pendingLeaveCount, 1);
    expect(store.clockLooksWrong(_now), isFalse);
  });

  test('every demo day follows the punch rules', () {
    for (final w in store.workersOf(demoProjectId)) {
      for (var d = 0; d < 7; d++) {
        final day = _today.subtract(Duration(days: d));
        expect(AttendanceStore.validDay(store.punchesFor(w.id, day)), isTrue,
            reason: '${w.name} on $day');
      }
    }
  });

  test('today: who is in, who is late, who is on leave', () {
    final today = store.projectToday(demoProjectId, now: _now);
    final gateA = today.locations.firstWhere((l) => l.site.id == 'demo-site-a');
    expect(gateA.working.map((w) => w.name), contains('Asha'));
    expect(gateA.onBreak.map((w) => w.name), contains('Imran'));
    expect(today.onLeave.map((w) => w.name), ['Kumar']);
    expect(today.notIn.map((w) => w.name), ['Joseph']);
    expect(today.late, greaterThanOrEqualTo(1)); // Ravi at 08:22
  });

  test('the correction waiting fits its day when approved', () async {
    final request = store.corrections
        .firstWhere((c) => c.status == RequestStatus.pending);
    await store.decideCorrection(request.id, approve: true);
    expect(store.corrections.first.replacedAuto, isTrue);
  });

  test('loading twice adds nothing', () async {
    final before = store.workers.length;
    await loadDemoData(store, now: _now);
    expect(store.workers.length, before);
  });

  test('removing takes out the demo and leaves real data alone', () async {
    await removeDemoData(store);
    expect(hasDemoData(store), isFalse);
    expect(store.workers.map((w) => w.id), ['real-1']);
    expect(store.sites.map((s) => s.id), ['real-site']);
    expect(store.lastPunchFor('real-1'), isNotNull);
    expect(store.pendingCorrectionCount, 0);
    expect(store.pendingLeaveCount, 0);
    expect(store.overtimeDecisions, isEmpty);

    // And it is all saved, not just in memory.
    final reloaded = await AttendanceStore.load();
    expect(reloaded.workers.map((w) => w.id), ['real-1']);
    expect(reloaded.projectById(demoProjectId), isNull);
  });
}
