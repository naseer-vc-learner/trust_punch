import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trust_punch/src/connected/device_token.dart';
import 'package:trust_punch/src/connected/punch_sync.dart';
import 'package:trust_punch/src/connected/server_api.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/store/attendance_database.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

const _site = Site(
  id: 's1',
  name: 'Gate A',
  latitude: 25.2048,
  longitude: 55.2708,
  projectId: 'p1',
);
const _asha = Worker(
  id: 'w1',
  employeeId: 'E1',
  name: 'Asha',
  embeddings: [],
  projectId: 'p1',
);
const _demo = Worker(
  id: 'demo-w9',
  employeeId: 'D9',
  name: 'Demo person',
  embeddings: [],
  projectId: 'p1',
);

Punch _punch(Worker w, PunchType type, DateTime at) => Punch(
      type: type,
      at: at,
      workerId: w.id,
      employeeId: w.employeeId,
      workerName: w.name,
      siteId: _site.id,
      siteName: _site.name,
      latitude: 25.2049,
      longitude: 55.2708,
      distanceMeters: 11,
    );

DateTime _yesterday(int h) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - 1, h);
}

/// A stand-in for the FastAPI server, on this machine's loopback.
class _FakeServer {
  late HttpServer _http;
  final stored = <String, Map<String, dynamic>>{};
  final batches = <List<Map<String, dynamic>>>[];
  String code = '123456';
  String token = 'device-token';

  /// Store the next batch but answer 500, as if the answer were lost.
  bool loseNextAnswer = false;
  bool forgetDevices = false;

  /// What /open-session answers: null = checked out.
  bool? openOnThisPhone;

  Uri get url => Uri.parse('http://127.0.0.1:${_http.port}');

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen(_handle);
  }

  Future<void> close() => _http.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    Map<String, dynamic> json() => jsonDecode(body) as Map<String, dynamic>;
    void answer(int status, Object reply) => req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(reply))
      ..close();

    switch (req.uri.path) {
      case '/health':
        answer(200, {
          'status': 'ok',
          'version': '0.2.0',
          'serverTime': DateTime.now().toUtc().toIso8601String(),
        });
      case final path when path.endsWith('/open-session'):
        final on = openOnThisPhone;
        answer(200, {'open': on != null, 'onThisPhone': on ?? false});
      case '/devices/pair':
        json()['code'] == code
            ? answer(200, {'deviceId': 'd1', 'token': token})
            : answer(403, {'detail': 'Code not valid'});
      case '/punches/batch':
        if (forgetDevices ||
            req.headers.value('authorization') != 'Bearer $token') {
          answer(401, {'detail': 'Not paired'});
          return;
        }
        final punches = [
          for (final p in json()['punches'] as List) p as Map<String, dynamic>,
        ];
        batches.add(punches);
        final accepted = <String>[], duplicates = <String>[];
        for (final p in punches) {
          final id = p['id'] as String;
          (stored.containsKey(id) ? duplicates : accepted).add(id);
          stored[id] = p;
        }
        if (loseNextAnswer) {
          loseNextAnswer = false;
          answer(500, {'detail': 'lost'});
          return;
        }
        answer(200, {
          'accepted': accepted,
          'duplicates': duplicates,
          'rejected': [],
          'flags': {},
        });
      default:
        answer(404, {'detail': 'Not Found'});
    }
  }
}

void main() {
  late _FakeServer server;
  late AttendanceStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    server = _FakeServer();
    await server.start();
    store = await AttendanceStore.load();
    await store.addSite(_site);
    await store.addWorker(_asha);
    await store.addWorker(_demo);
  });
  tearDown(() => server.close());

  PunchSync sync({String? token}) => PunchSync(
        store: store,
        api: ServerApi(baseUrl: server.url),
        tokens: MemoryTokenStore(token),
        every: const Duration(hours: 1),
      );

  Future<void> day(Worker w) async {
    for (final (type, h) in [(PunchType.checkIn, 7), (PunchType.checkOut, 16)]) {
      final at = _yesterday(h);
      await store.recordPunch(store.planAt(w.id, _site, now: at),
          _punch(w, type, at));
    }
  }

  group('server address', () {
    test('none means no server and no network', () {
      expect(serverConfigured, isFalse);
      expect(ServerApi.fromEnvironment(), isNull);
    });

    test('plain http only to this phone itself', () {
      expect(() => ServerApi(baseUrl: Uri.parse('http://192.168.1.5:8443')),
          throwsArgumentError);
      expect(ServerApi(baseUrl: Uri.parse('https://192.168.1.5:8443')),
          isNotNull);
    });

    test('health: up, or reported as down without throwing', () async {
      expect((await ServerApi(baseUrl: server.url).health()).ok, isTrue);
      final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = unused.port;
      await unused.close();
      final down =
          await ServerApi(baseUrl: Uri.parse('http://127.0.0.1:$port')).health();
      expect(down.ok, isFalse);
      expect(down.error, 'Not reachable');
    });
  });

  test('every saved punch has a permanent id, and keeps it', () async {
    await day(_asha);
    final ids = store.punchesFor(_asha.id, _yesterday(0)).map((p) => p.id);
    expect(ids.every((id) => id != null && id.length == 36), isTrue);
    final again = await AttendanceStore.load();
    expect(again.punchesFor(_asha.id, _yesterday(0)).map((p) => p.id), ids);
  });

  test('nothing is sent until the phone is paired', () async {
    await day(_asha);
    final s = sync();
    await s.start();
    expect(s.paired, isFalse);
    expect(s.waiting, 2);
    expect(server.batches, isEmpty);
    s.dispose();
  });

  test('pairing with a wrong code is refused', () async {
    final s = sync();
    await s.start();
    await expectLater(
      s.pair('000000', 'Gate'),
      throwsA(isA<ServerException>()
          .having((e) => e.problem, 'problem', ServerProblem.refused)),
    );
    expect(s.paired, isFalse);
    s.dispose();
  });

  test('once paired, punches go up; demo data stays on the phone', () async {
    await day(_asha);
    await day(_demo);
    final s = sync();
    await s.start();
    await s.pair('123456', 'Gate');
    await s.syncNow();

    expect(s.waiting, 0);
    expect(server.stored, hasLength(2));
    expect(server.stored.values.every((p) => p['workerId'] == 'w1'), isTrue);
    expect(store.punchesSentAs(AttendanceDatabase.keptOnPhone), 2);

    final sent = server.stored.values.first;
    expect(sent['at'], endsWith('Z'));
    expect(sent['offsetMinutes'], _yesterday(7).timeZoneOffset.inMinutes);
    expect(sent['siteLat'], _site.latitude);
    s.dispose();
  });

  test('every attempt says what it did, even with nothing to send',
      () async {
    final s = sync(token: server.token);
    await s.start();
    await s.syncNow();
    expect(s.lastOutcome!.summary,
        'Nothing waiting: everything is already on the server');

    await day(_asha);
    await day(_demo);
    await s.syncNow();
    expect(s.lastOutcome!.summary, 'Sent 2 punches · 2 demo kept on phone');

    await server.close();
    await day(_asha);
    await s.syncNow();
    expect(s.lastOutcome!.summary, startsWith('Not sent:'));
    s.dispose();
  });

  test('a lost answer is resent and counted once', () async {
    await day(_asha);
    server.loseNextAnswer = true;
    final s = sync(token: server.token);
    await s.start();
    await s.syncNow();
    await s.syncNow();

    expect(server.batches.length, greaterThanOrEqualTo(2),
        reason: 'sent again: the first answer never arrived');
    expect(server.stored, hasLength(2), reason: 'but stored once each');
    expect(s.waiting, 0);
    s.dispose();
  });

  test('a server that forgot the phone asks for pairing again', () async {
    await day(_asha);
    server.forgetDevices = true;
    final s = sync(token: server.token);
    await s.start();
    await s.syncNow();
    expect(s.paired, isFalse);
    expect(s.problem!.problem, ServerProblem.notPaired);
    expect(s.waiting, 2, reason: 'kept for the next pairing');
    s.dispose();
  });

  test('a correction tells the server which punch it replaces', () async {
    final s = sync(token: server.token);
    await s.start();
    final at = _yesterday(7);
    await store.recordPunch(store.planAt(_asha.id, _site, now: at),
        _punch(_asha, PunchType.checkIn, at));
    // Forgot to check out: the next day's check-in closes it automatically.
    final next = at.add(const Duration(days: 1));
    await store.recordPunch(store.planAt(_asha.id, _site, now: next),
        _punch(_asha, PunchType.checkIn, next));
    await s.syncNow();
    final auto = store.punchesFor(_asha.id, at).firstWhere((p) => p.auto);

    final request = await store.requestCorrection(
      worker: _asha,
      site: _site,
      type: PunchType.checkOut,
      at: _yesterday(15),
      reason: 'Forgot',
    );
    await store.decideCorrection(request.id, approve: true);
    await s.syncNow();

    final fix = server.batches.last.single;
    expect(fix['corrected'], isTrue);
    expect(fix['replaces'], auto.id);
    s.dispose();
  });

  test('asks the server whether the worker is on the clock elsewhere',
      () async {
    final s = sync(token: server.token);
    await s.start();
    server.openOnThisPhone = false; // checked in on another phone
    expect(await s.checkedInElsewhere(_asha), isTrue);
    server.openOnThisPhone = true; // on this phone: the local rule decides
    expect(await s.checkedInElsewhere(_asha), isFalse);
    server.openOnThisPhone = null; // not checked in
    expect(await s.checkedInElsewhere(_asha), isFalse);
    expect(await s.checkedInElsewhere(_demo), isNull, reason: 'demo stays local');

    await server.close();
    expect(await s.checkedInElsewhere(_asha), isNull,
        reason: 'offline: cannot tell, so the punch goes ahead');
    s.dispose();
  });

  test('unpaired, it cannot tell either', () async {
    final s = sync();
    await s.start();
    expect(await s.checkedInElsewhere(_asha), isNull);
    s.dispose();
  });

  test('an older database gets ids for its punches on upgrade', () async {
    final dir = Directory.systemTemp.createTempSync('tp_v1');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/a.db';
    final v1 = sqlite3.open(path);
    v1.execute('''
      CREATE TABLE punches (id INTEGER PRIMARY KEY, worker_id TEXT NOT NULL,
        at INTEGER NOT NULL, day INTEGER NOT NULL, type TEXT NOT NULL,
        employee_id TEXT NOT NULL, worker_name TEXT NOT NULL,
        site_id TEXT NOT NULL, site_name TEXT NOT NULL, lat REAL NOT NULL,
        lng REAL NOT NULL, distance REAL NOT NULL, flags INTEGER NOT NULL,
        photo TEXT);
      CREATE TABLE records (kind TEXT NOT NULL, id TEXT NOT NULL,
        json TEXT NOT NULL, UNIQUE (kind, id));
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      INSERT INTO punches VALUES (1, 'w1', 1772420000000000, 20270302,
        'checkIn', 'E1', 'Asha', 's1', 'Gate A', 25.2, 55.27, 3, 0, NULL);
      PRAGMA user_version = 1;
    ''');
    v1.close();

    final db = AttendanceDatabase.open(path);
    final punches = db.punchesToSend(10);
    expect(punches.single.id, hasLength(36));
    expect(punches.single.workerName, 'Asha');
    db.close();
  });
}
