import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/screens/project_screens.dart';
import 'package:trust_punch/src/services/face_recognizer.dart';
import 'package:trust_punch/src/services/location_service.dart';
import 'package:trust_punch/src/services/speech_service.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

void main() {
  late AttendanceStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await AttendanceStore.load();
  });

  Future<void> pumpProjects(WidgetTester tester) => tester.pumpWidget(
        MaterialApp(
          home: ProjectsScreen(
            store: store,
            recognizer: FaceRecognizer(),
            speech: SpeechService(),
          ),
        ),
      );

  Future<void> typeAndSave(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('create a project, then add a job and a role', (tester) async {
    await pumpProjects(tester);
    expect(find.text('No projects yet'), findsOneWidget);

    await tester.tap(find.text('New project'));
    await tester.pumpAndSettle();
    await typeAndSave(tester, 'Al Wasl Tower');

    // Creating a project opens it.
    expect(find.text('Al Wasl Tower'), findsOneWidget);
    expect(find.text('Jobs (activities)'), findsOneWidget);

    await tester.tap(find.text('Add job'));
    await tester.pumpAndSettle();
    await typeAndSave(tester, 'Block A foundation');

    await tester.tap(find.text('Add role'));
    await tester.pumpAndSettle();
    await typeAndSave(tester, 'Mason');

    final project = store.projects.single;
    expect(project.name, 'Al Wasl Tower');
    expect(project.jobs, ['Block A foundation']);
    expect(project.roles, ['Mason']);
    expect(find.text('Block A foundation'), findsOneWidget);
    expect(find.text('Mason'), findsOneWidget);
  });

  group('typed coordinates', () {
    test('valid pairs parse, with spaces trimmed', () {
      expect(parseLatLng(' 25.2048', '55.2708 '), (25.2048, 55.2708));
      expect(parseLatLng('-33.8688', '151.2093'), (-33.8688, 151.2093));
    });

    test('out of range, text and blanks are refused', () {
      expect(parseLatLng('95', '55'), isNull);
      expect(parseLatLng('25', '181'), isNull);
      expect(parseLatLng('abc', '55'), isNull);
      expect(parseLatLng('', ''), isNull);
      expect(parseLatLng('NaN', '55'), isNull);
      expect(parseLatLng('Infinity', '55'), isNull);
    });

    test('a pair pasted from a map app is split', () {
      expect(splitLatLngPair('25.2048, 55.2708'), ('25.2048', '55.2708'));
      expect(splitLatLngPair('25.2048 55.2708'), ('25.2048', '55.2708'));
      expect(splitLatLngPair('25.2048'), isNull);
      expect(splitLatLngPair('1, 2, 3'), isNull);
    });
  });

  testWidgets('a location can be added by pasting coordinates',
      (tester) async {
    final project = await store.addProject('Al Wasl Tower');
    await tester.pumpWidget(MaterialApp(
      home: ProjectScreen(
        store: store,
        recognizer: FaceRecognizer(),
        speech: SpeechService(),
        projectId: project.id,
        initialTab: 1,
      ),
    ));

    await tester.scrollUntilVisible(find.text('Enter coordinates'), 200,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last);
    await tester.tap(find.text('Enter coordinates'));
    await tester.pumpAndSettle();
    await typeAndSave(tester, 'Gate B');

    // Pasted into the latitude field, the pair splits across both.
    await tester.enterText(find.byType(TextField).first, '25.2048, 55.2708');
    await tester.pumpAndSettle();
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.first.controller!.text, '25.2048');
    expect(fields.last.controller!.text, '55.2708');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Then the shift, kept at its 09:00–17:00 default.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final site = store.sitesOf(project.id).single;
    expect(site.name, 'Gate B');
    expect(site.latitude, 25.2048);
    expect(site.longitude, 55.2708);
    expect(site.shiftStartMinutes, 9 * 60);
    expect(find.textContaining('25.20480, 55.27080'), findsOneWidget);
  });

  testWidgets('impossible coordinates are refused with a message',
      (tester) async {
    (double, double)? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              result = await askCoordinates(context, lang: 'en'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '95');
    await tester.enterText(find.byType(TextField).last, '55');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('latitude −90 to 90'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('the shift dialog refuses an end before the start',
      (tester) async {
    (int, int)? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              result = await askShift(context, lang: 'en', start: 600, end: 540),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('10:00'), findsOneWidget);
    expect(find.text('09:00'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('The shift must end after it starts'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('a worker on the project can be given a role and job',
      (tester) async {
    final project = await store.addProject('Al Wasl Tower');
    await store.updateProject(
        project.copyWith(jobs: ['MEP first fix'], roles: ['Electrician']));
    await store.addWorker(Worker(
      id: 'w1',
      employeeId: 'E1',
      name: 'Ravi',
      embeddings: const [],
      projectId: project.id,
    ));

    await tester.pumpWidget(MaterialApp(
      home: ProjectScreen(
        store: store,
        recognizer: FaceRecognizer(),
        speech: SpeechService(),
        projectId: project.id,
        initialTab: 1,
      ),
    ));
    await tester.scrollUntilVisible(find.text('Ravi'), 200,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last);
    await tester.tap(find.text('Ravi'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Electrician').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('MEP first fix').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final ravi = store.workers.single;
    expect(ravi.role, 'Electrician');
    expect(ravi.job, 'MEP first fix');
    expect(find.text('Electrician · MEP first fix'), findsOneWidget);
  });
}
