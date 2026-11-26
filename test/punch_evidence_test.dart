import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/screens/project_screens.dart';
import 'package:trust_punch/src/screens/punch_result_screen.dart';
import 'package:trust_punch/src/services/face_recognizer.dart';
import 'package:trust_punch/src/services/punch_photo_store.dart';
import 'package:trust_punch/src/services/speech_service.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

const _a = Site(
  id: 'A',
  name: 'Gate A',
  latitude: 25.2000,
  longitude: 55.2700,
  projectId: 'p1',
);
const _b = Site(
  id: 'B',
  name: 'Gate B',
  latitude: 25.2450,
  longitude: 55.2700,
  projectId: 'p1',
);
Worker _worker(String id, String name) => Worker(
      id: id,
      employeeId: id.toUpperCase(),
      name: name,
      embeddings: const [],
      projectId: 'p1',
      role: 'Mason',
    );
final _asha = _worker('w1', 'Asha');
final _ravi = _worker('w2', 'Ravi');
final _sam = _worker('w3', 'Sam');

Punch _punch(Worker w, PunchType type, Site site, DateTime at) => Punch(
      type: type,
      at: at,
      workerId: w.id,
      employeeId: w.employeeId,
      workerName: w.name,
      siteId: site.id,
      siteName: site.name,
      latitude: site.latitude,
      longitude: site.longitude,
      distanceMeters: 0,
    );

void main() {
  late AttendanceStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'flutter.projects': [
        jsonEncode({'id': 'p1', 'name': 'Al Wasl Tower'}),
      ],
    });
    store = await AttendanceStore.load();
    for (final s in [_a, _b]) {
      await store.addSite(s);
    }
    for (final w in [_asha, _ravi, _sam]) {
      await store.addWorker(w);
    }
  });

  Future<void> punch(Worker w, PunchType type, Site site, DateTime at) async {
    final plan = store.planAt(w.id, site, now: at);
    await store.recordPunch(plan, _punch(w, type, site, at));
  }

  group('project today', () {
    final day = DateTime(2027, 3, 2);
    DateTime at(int h, [int m = 0]) => day.add(Duration(hours: h, minutes: m));

    test('who is where, hours per location, and what to check', () async {
      // Asha: Gate A from 07:00, moves to Gate B at 12:00 without checking out.
      await punch(_asha, PunchType.checkIn, _a, at(7));
      await punch(_asha, PunchType.checkIn, _b, at(12));
      // Ravi: Gate A from 09:30 (late), on break since 13:00.
      await punch(_ravi, PunchType.checkIn, _a, at(9, 30));
      await punch(_ravi, PunchType.breakStart, _a, at(13));
      // Sam: nothing today.

      final today = store.projectToday('p1', now: at(14));
      final gateA = today.locations.firstWhere((l) => l.site.id == 'A');
      final gateB = today.locations.firstWhere((l) => l.site.id == 'B');

      expect(gateA.working, isEmpty);
      expect(gateA.onBreak.map((w) => w.name), ['Ravi']);
      expect(gateB.working.map((w) => w.name), ['Asha']);
      expect(today.onSite, 2);
      expect(today.notIn.map((w) => w.name), ['Sam']);

      // Gate A: Asha 07:00–11:50 (auto close) + Ravi 09:30–13:00.
      expect(gateA.hoursToday.inMinutes, closeTo(290 + 210, 1));
      expect(today.late, 1); // Ravi, after 09:10
      expect(today.autoCheckouts, 1); // Asha
      expect(today.travel.inMinutes, closeTo(10, 1));
    });

    test('a session left open yesterday is not "on site" today', () async {
      await punch(_asha, PunchType.checkIn, _a, at(7));
      final nextDay = store.projectToday('p1', now: at(24 + 8));
      expect(nextDay.onSite, 0);
      expect(nextDay.notIn.map((w) => w.name), contains('Asha'));
    });
  });

  group('punch selfies', () {
    late Directory dir;
    late PunchPhotoStore photos;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('punch_photos_test');
      photos = PunchPhotoStore(dir);
      PunchPhotoStore.debugUse(photos);
    });

    tearDown(() async {
      PunchPhotoStore.debugUse(null);
      await dir.delete(recursive: true);
    });

    test('saves under a safe name, and delete-all empties the folder',
        () async {
      final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
      final name = await photos.save(
        bytes,
        workerId: '../evil/w1',
        at: DateTime(2027, 3, 2, 7),
      );
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains('..')));
      expect(await photos.fileFor(name).readAsBytes(), bytes);

      await photos.deleteAll();
      expect(dir.listSync(), isEmpty);
    });

    test('the photo name survives saving and loading the punch', () async {
      final at = DateTime(2027, 3, 2, 7);
      final plan = store.planAt(_asha.id, _a, now: at);
      await store.recordPunch(
        plan,
        Punch(
          type: PunchType.checkIn,
          at: at,
          workerId: _asha.id,
          employeeId: _asha.employeeId,
          workerName: _asha.name,
          siteId: _a.id,
          siteName: _a.name,
          latitude: _a.latitude,
          longitude: _a.longitude,
          distanceMeters: 0,
          photo: 'w1_123.jpg',
        ),
      );
      final reloaded = await AttendanceStore.load();
      expect(reloaded.lastPunchFor(_asha.id)!.photo, 'w1_123.jpg');
    });
  });

  group('result screens', () {
    testWidgets('green screen shows who, what, where and closes itself',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PunchSuccessScreen(
                lang: 'en',
                workerName: 'Asha',
                type: PunchType.checkIn,
                siteName: 'Gate B',
                at: DateTime(2027, 3, 2, 12),
                autoCheckout: 'Gate A: automatic check-out at 11:50',
                showFor: const Duration(seconds: 2),
              ),
            )),
            child: const Text('punch'),
          ),
        ),
      ));
      await tester.tap(find.text('punch'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Asha'), findsOneWidget);
      expect(find.text('Started work'), findsOneWidget);
      expect(find.text('Gate B · 12:00'), findsOneWidget);
      expect(find.text('Gate A: automatic check-out at 11:50'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byType(PunchSuccessScreen), findsNothing);
      expect(find.text('punch'), findsOneWidget);
    });

    testWidgets('red screen shows the reason and offers to try again',
        (tester) async {
      var retried = false;
      await tester.pumpWidget(MaterialApp(
        home: PunchFailureView(
          message: 'Face not known. Try again.',
          lang: 'en',
          onRetry: () => retried = true,
          onClose: () {},
        ),
      ));
      expect(find.text('Not done'), findsOneWidget);
      expect(find.text('Face not known. Try again.'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(retried, isTrue);
    });
  });

  testWidgets('the Today tab shows people at their location',
      (tester) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 0, 1);
    await punch(_asha, PunchType.checkIn, _b, start);

    await tester.pumpWidget(MaterialApp(
      home: ProjectScreen(
        store: store,
        recognizer: FaceRecognizer(),
        speech: SpeechService(),
        projectId: 'p1',
      ),
    ));
    await tester.pump();

    expect(find.text('Gate A'), findsOneWidget);
    expect(find.text('Gate B'), findsOneWidget);
    expect(find.text('Asha · Mason'), findsOneWidget);
    expect(find.text('Nobody here right now'), findsOneWidget); // Gate A
    expect(find.text('Ravi · Mason'), findsOneWidget); // under "Not in"
  });
}
