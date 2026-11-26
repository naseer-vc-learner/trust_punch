import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/models/attendance.dart';
import 'package:trust_punch/src/screens/project_screens.dart';
import 'package:trust_punch/src/services/face_recognizer.dart';
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
      ),
    ));
    await tester.scrollUntilVisible(find.text('Ravi'), 200);
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
