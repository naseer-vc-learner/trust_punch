import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/connected/device_token.dart';
import 'package:trust_punch/src/connected/punch_sync.dart';
import 'package:trust_punch/src/connected/server_api.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

/// Phone → real FastAPI server, end to end. Skipped unless pointed at one:
///
///     cd backend && TRUSTPUNCH_DB=/tmp/tp-e2e.db \
///       .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8765 &
///     CODE=$(TRUSTPUNCH_DB=/tmp/tp-e2e.db .venv/bin/python -m app.cli pair-code | grep -o '[0-9]\{6\}')
///     cd .. && TRUSTPUNCH_TEST_SERVER=http://127.0.0.1:8765 \
///       TRUSTPUNCH_PAIR_CODE=$CODE flutter test test/real_server_test.dart
final _server = Platform.environment['TRUSTPUNCH_TEST_SERVER'];
final _code = Platform.environment['TRUSTPUNCH_PAIR_CODE'];

void main() {
  test('pair, upload a day, resend it, and see the server flag a bad fix',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await AttendanceStore.load();
    const site = Site(
      id: 'e2e-site',
      name: 'Gate A',
      latitude: 25.2048,
      longitude: 55.2708,
      projectId: 'p1',
    );
    const asha = Worker(
      id: 'e2e-w1',
      employeeId: 'E1',
      name: 'Asha',
      embeddings: [],
      projectId: 'p1',
    );
    await store.addSite(site);
    await store.addWorker(asha);
    final n = DateTime.now();
    final day = DateTime(n.year, n.month, n.day - 1);
    for (final (type, h, lat) in [
      (PunchType.checkIn, 7, 25.2049),
      // Claims to be at the gate but the fix is ~1 km away.
      (PunchType.checkOut, 16, 25.2140),
    ]) {
      final at = day.add(Duration(hours: h));
      await store.recordPunch(
        store.planAt(asha.id, site, now: at),
        Punch(
          type: type,
          at: at,
          workerId: asha.id,
          employeeId: asha.employeeId,
          workerName: asha.name,
          siteId: site.id,
          siteName: site.name,
          latitude: lat,
          longitude: 55.2708,
          distanceMeters: 11,
        ),
      );
    }

    final sync = PunchSync(
      store: store,
      api: ServerApi(baseUrl: Uri.parse(_server!)),
      tokens: MemoryTokenStore(),
      every: const Duration(hours: 1),
    );
    await sync.start();
    await sync.checkHealth();
    expect(sync.health?.ok, isTrue);
    await sync.pair(_code!, 'e2e test');
    await sync.syncNow();

    expect(sync.problem, isNull);
    expect(sync.waiting, 0);
    final out = store.punchesFor(asha.id, day).last;
    expect(sync.flags[out.id], containsAll(['far_from_site', 'distance_mismatch']));

    // Resend everything: the server answers "already have it".
    final again = await sync.api.uploadPunches(
      (await sync.tokens.read())!,
      [for (final p in store.punchesFor(asha.id, day)) sync.toServer(p)],
    );
    expect(again.accepted, isEmpty);
    expect(again.duplicates, hasLength(2));
    sync.dispose();
  }, skip: _server == null || _code == null
      ? 'Set TRUSTPUNCH_TEST_SERVER and TRUSTPUNCH_PAIR_CODE to run'
      : false);
}
