import 'package:flutter/material.dart';

import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../models/project.dart';
import '../services/face_recognizer.dart';
import '../services/speech_service.dart';
import '../services/supervisor_lock.dart';
import '../store/attendance_store.dart';
import 'enroll_screen.dart';
import 'project_screens.dart' show askAssignment;
import 'shared_widgets.dart' show showSnack;
import 'supervisor_pin.dart';

/// Registers a new worker: name and badge number, three face angles, then
/// their project, role and job.
///
/// [projectId] set (from a project's page): the worker joins that project.
/// Null (from the Workers screen): the supervisor picks one, or the worker
/// joins the only project there is.
Future<void> registerWorkerFlow(
  BuildContext context, {
  required AttendanceStore store,
  required FaceRecognizer recognizer,
  required SpeechService speech,
  String? projectId,
}) async {
  final lang = store.languageCode;
  final details = await showDialog<(String, String)>(
    context: context,
    builder: (_) => _DetailsDialog(lang: lang),
  );
  if (details == null || !context.mounted) return;

  final embeddings = await Navigator.of(context).push<List<List<double>>>(
    MaterialPageRoute(
      builder: (_) => EnrollScreen(
        recognizer: recognizer,
        speech: speech,
        lang: lang,
      ),
    ),
  );
  if (embeddings == null || embeddings.isEmpty || !context.mounted) return;

  // One face, one identity. Without this the same person could register
  // twice under different names and be paid for both.
  final duplicate = recognizer.findDuplicate(embeddings, store.workers);
  if (duplicate != null) {
    showSnack(context, '${t(lang, T.faceAlreadyRegistered)}: ${duplicate.name}');
    return;
  }

  final project = await _pickProject(context, store, projectId);
  if (project == null || !context.mounted) return;

  // The face is already captured, so cancelling here still registers the
  // worker, just without a role or job yet.
  final assignment = await askAssignment(context, lang: lang, project: project);

  await store.addWorker(Worker(
    id: DateTime.now().microsecondsSinceEpoch.toString(),
    employeeId: details.$2,
    name: details.$1,
    embeddings: embeddings,
    projectId: project.id,
    role: assignment?.$1 ?? '',
    job: assignment?.$2 ?? '',
  ));
}

Future<Project?> _pickProject(
  BuildContext context,
  AttendanceStore store,
  String? projectId,
) async {
  if (projectId != null) return store.projectById(projectId);
  final projects = store.projects;
  if (projects.isEmpty) {
    // Every worker must be on a project to punch anywhere.
    final existing = store.projectById(generalProjectId);
    return existing ?? await store.addProject('General');
  }
  if (projects.length == 1) return projects.first;
  return showDialog<Project>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(t(store.languageCode, T.projects)),
      children: [
        for (final p in projects)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, p),
            child: Text(p.name),
          ),
      ],
    ),
  );
}

class _DetailsDialog extends StatefulWidget {
  const _DetailsDialog({required this.lang});

  final String lang;

  @override
  State<_DetailsDialog> createState() => _DetailsDialogState();
}

class _DetailsDialogState extends State<_DetailsDialog> {
  final _name = TextEditingController();
  final _employeeId = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _employeeId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lang = widget.lang;
    return AlertDialog(
      title: Text(t(lang, T.addWorker)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: t(lang, T.name)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _employeeId,
            decoration: InputDecoration(labelText: t(lang, T.employeeIdLabel)),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t(lang, T.cancel)),
        ),
        FilledButton(
          onPressed: () {
            final n = _name.text.trim();
            if (n.isNotEmpty) {
              Navigator.pop(context, (n, _employeeId.text.trim()));
            }
          },
          child: Text(t(lang, T.save)),
        ),
      ],
    );
  }
}

/// The people this phone can recognise, across all projects.
///
/// Several on one device is the realistic setup: labourers often do not carry
/// a smartphone, so the phone lives at the gate and everyone uses it.
class WorkersScreen extends StatefulWidget {
  const WorkersScreen({
    super.key,
    required this.store,
    required this.lock,
    required this.recognizer,
    required this.speech,
  });

  final AttendanceStore store;
  final SupervisorLock lock;
  final FaceRecognizer recognizer;
  final SpeechService speech;

  @override
  State<WorkersScreen> createState() => _WorkersScreenState();
}

class _WorkersScreenState extends State<WorkersScreen> {
  String get _lang => widget.store.languageCode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t(_lang, T.workers)),
        actions: [
          IconButton(
            tooltip: t(_lang, T.changePin),
            icon: const Icon(Icons.password),
            onPressed: () async {
              final changed =
                  await changeSupervisorPin(context, widget.lock, _lang);
              if (changed && context.mounted) {
                showSnack(context, t(_lang, T.pinChanged));
              }
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final store = widget.store;
          final workers = store.workers;
          return Column(
            children: [
              Expanded(
                child: workers.isEmpty
                    ? Center(child: Text(t(_lang, T.noWorkers)))
                    : ListView.builder(
                        itemCount: workers.length,
                        itemBuilder: (context, i) {
                          final worker = workers[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            child: ListTile(
                              leading: CircleAvatar(
                                child: Text(worker.name.characters.first),
                              ),
                              title: Text(worker.name),
                              // One line per project: name, role, job.
                              subtitle: Text([
                                if (worker.employeeId.isNotEmpty)
                                  worker.employeeId,
                                for (final a in worker.assignments)
                                  [
                                    store.projectById(a.projectId)?.name ?? '',
                                    a.role,
                                    a.job,
                                  ].where((s) => s.isNotEmpty).join(' · '),
                              ].where((s) => s.isNotEmpty).join('\n')),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => store.removeWorker(worker.id),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: () => registerWorkerFlow(
                    context,
                    store: store,
                    recognizer: widget.recognizer,
                    speech: widget.speech,
                  ),
                  icon: const Icon(Icons.person_add),
                  label: Text(t(_lang, T.addWorker)),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
