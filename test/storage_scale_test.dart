import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/models/project.dart';
import 'package:trust_punch/src/store/attendance_database.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

/// A busy gate: 3,000 workers, four punches each a day (in, break, back,
/// out) = 12,000 punches a day, for a week, in a real database file.
///
/// Limits are loose on purpose, so a slow CI machine does not fail them,
/// yet far below what the old storage took (it re-encoded the whole
/// history on every punch; the test prints that cost for comparison).
const _workerCount = 3000;
const _days = 7;

const _gateA = Site(
  id: 'a',
  name: 'Gate A',
  latitude: 25.2,
  longitude: 55.27,
  projectId: 'p',
  shiftStartMinutes: 7 * 60,
  shiftEndMinutes: 16 * 60,
);

Worker _worker(int i) => Worker(
      id: 'w$i',
      employeeId: 'E$i',
      name: 'Worker $i',
      embeddings: const [],
      projectId: 'p',
    );

Punch _punch(Worker w, PunchType type, DateTime at) => Punch(
      type: type,
      at: at,
      workerId: w.id,
      employeeId: w.employeeId,
      workerName: w.name,
      siteId: _gateA.id,
      siteName: _gateA.name,
      latitude: 25.2,
      longitude: 55.27,
      distanceMeters: 3,
    );

/// [n] punches, timed in milliseconds each.
Future<List<double>> _timed(int n, Future<void> Function(int i) body) async {
  final times = <double>[];
  for (var i = 0; i < n; i++) {
    final sw = Stopwatch()..start();
    await body(i);
    times.add(sw.elapsedMicroseconds / 1000);
  }
  return times;
}

double _avg(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;

double _p95(List<double> xs) {
  final sorted = [...xs]..sort();
  return sorted[(sorted.length * 0.95).floor()];
}

void main() {
  test('12,000 punches a day: a punch costs the same on day 7 as on day 1',
      () async {
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('trust_punch_scale');
    addTearDown(() => dir.deleteSync(recursive: true));
    AttendanceDatabase.debugUse(AttendanceDatabase.open('${dir.path}/a.db'));

    var store = await AttendanceStore.load();
    final workers = [for (var i = 0; i < _workerCount; i++) _worker(i)];
    await store.batch(() async {
      await store.addProject('Busy gate', id: 'p');
      await store.updateProject(const Project(id: 'p', name: 'Busy gate'));
      await store.addSite(_gateA);
      for (final w in workers) {
        await store.addWorker(w);
      }
    });

    final now = DateTime.now();
    DateTime on(int daysAgo, int minutes) =>
        DateTime(now.year, now.month, now.day - daysAgo)
            .add(Duration(minutes: minutes));

    Future<void> punch(int i, PunchType type, DateTime at) => store.recordPunch(
          store.planAt(workers[i].id, _gateA, now: at),
          _punch(workers[i], type, at),
        );

    // Each worker's four punches, a second apart per worker so the gate
    // queue is in time order. [from] skips check-ins already made.
    Future<void> restOfDay(int daysAgo, {int from = 0}) async {
      for (final (type, start) in [
        (PunchType.checkIn, 6 * 60 + 30),
        (PunchType.breakStart, 12 * 60),
        (PunchType.breakEnd, 12 * 60 + 30),
        (PunchType.checkOut, 16 * 60),
      ]) {
        final first = type == PunchType.checkIn ? from : 0;
        for (var i = first; i < workers.length; i++) {
          await punch(i, type, on(daysAgo, start).add(Duration(seconds: i)));
        }
      }
    }

    // Day 1: the first 300 check-ins timed one by one, each its own
    // transaction, as at the gate. The rest of the week goes in batches.
    Future<List<double>> timedCheckIns(int daysAgo) => _timed(
          300,
          (i) => punch(i, PunchType.checkIn,
              on(daysAgo, 6 * 60 + 30).add(Duration(seconds: i))),
        );
    final firstDay = await timedCheckIns(_days - 1);

    final seed = Stopwatch()..start();
    await store.batch(() => restOfDay(_days - 1, from: 300));
    for (var d = _days - 2; d >= 1; d--) {
      await store.batch(() => restOfDay(d));
    }
    seed.stop();

    // A restart with a week behind it.
    final load = Stopwatch()..start();
    store = await AttendanceStore.load();
    load.stop();
    final inMemory = [
      for (var d = 0; d < _days; d++)
        store.punchesOn(on(d, 0)).length,
    ].reduce((a, b) => a + b);
    expect(inMemory, (_days - 1) * _workerCount * 4);

    // Day 7, same 300 check-ins, now with 72,000 punches recorded.
    final lastDay = await timedCheckIns(0);

    // What the screens ask for, every second while open.
    final board = Stopwatch()..start();
    final today = store.projectToday('p');
    var working = 0;
    for (final w in workers) {
      if (store.statusOf(w.id) == WorkerStatus.working) working++;
    }
    board.stop();
    expect(today.notIn, hasLength(_workerCount - 300));
    expect(working, 300);

    final overtime = Stopwatch()..start();
    final pending = store.pendingOvertime.length;
    overtime.stop();
    final again = Stopwatch()..start();
    store.pendingOvertimeCount;
    again.stop();
    // 06:30–16:00 less a 30 min break is 9 h: 1 h over on every finished day.
    expect(pending, (_days - 1) * _workerCount);

    // The old storage, for comparison: one JSON list of everything,
    // re-encoded and rewritten on every punch.
    final all = [
      for (var d = 0; d < _days; d++) ...store.punchesOn(on(d, 0)),
    ];
    final old = Stopwatch()..start();
    final encoded = all.map((p) => jsonEncode(p.toJson())).toList();
    old.stop();
    final oldBytes = encoded.fold<int>(0, (s, e) => s + e.length);

    // ignore: avoid_print
    print('''
--- storage at 12,000 punches/day, $_workerCount workers ---
punch on day 1:   avg ${_avg(firstDay).toStringAsFixed(3)} ms, p95 ${_p95(firstDay).toStringAsFixed(3)} ms
punch on day 7:   avg ${_avg(lastDay).toStringAsFixed(3)} ms, p95 ${_p95(lastDay).toStringAsFixed(3)} ms
seed 6 days:      ${seed.elapsedMilliseconds} ms (${(_days - 1) * _workerCount * 4} punches)
restart (load):   ${load.elapsedMilliseconds} ms
today board:      ${board.elapsedMilliseconds} ms ($_workerCount workers)
pending overtime: ${overtime.elapsedMilliseconds} ms first, ${again.elapsedMicroseconds} µs cached
old storage:      ${old.elapsedMilliseconds} ms to re-encode ${(oldBytes / 1e6).toStringAsFixed(1)} MB — on every punch
''');

    // Flat: day 7 no slower than day 1 beyond noise, and far below the
    // old per-punch rewrite.
    expect(_avg(lastDay), lessThan(5));
    expect(_avg(lastDay), lessThan(_avg(firstDay) * 3 + 0.5));
    expect(load.elapsedMilliseconds, lessThan(5000));
    expect(board.elapsedMilliseconds, lessThan(1000));
    expect(again.elapsedMicroseconds, lessThan(1000));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
