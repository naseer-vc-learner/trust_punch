import 'package:flutter/material.dart';

import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../services/face_recognizer.dart';
import '../services/speech_service.dart';
import '../services/supervisor_lock.dart';
import '../store/attendance_store.dart';
import 'enroll_screen.dart';
import 'supervisor_pin.dart';

/// The people this phone can recognise.
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

  Future<void> _addWorker() async {
    final details = await _askDetails();
    if (details == null || !mounted) return;

    final embeddings = await Navigator.of(context).push<List<List<double>>>(
      MaterialPageRoute(
        builder: (_) => EnrollScreen(
          recognizer: widget.recognizer,
          speech: widget.speech,
          lang: _lang,
        ),
      ),
    );
    if (embeddings == null || embeddings.isEmpty || !mounted) return;

    // One face, one identity. Without this the same person could register
    // twice under different names and be paid for both.
    final duplicate =
        widget.recognizer.findDuplicate(embeddings, widget.store.workers);
    if (duplicate != null) {
      _snack('${t(_lang, T.faceAlreadyRegistered)}: ${duplicate.name}');
      return;
    }

    await widget.store.addWorker(Worker(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      employeeId: details.$2,
      name: details.$1,
      embeddings: embeddings,
    ));
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<(String, String)?> _askDetails() {
    final name = TextEditingController();
    final employeeId = TextEditingController();

    return showDialog<(String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t(_lang, T.addWorker)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: t(_lang, T.name)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: employeeId,
              decoration:
                  InputDecoration(labelText: t(_lang, T.employeeIdLabel)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t(_lang, T.cancel)),
          ),
          FilledButton(
            onPressed: () {
              final n = name.text.trim();
              if (n.isNotEmpty) {
                Navigator.pop(context, (n, employeeId.text.trim()));
              }
            },
            child: Text(t(_lang, T.save)),
          ),
        ],
      ),
    );
  }

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
              if (changed && mounted) _snack(t(_lang, T.pinChanged));
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final workers = widget.store.workers;
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
                              subtitle: Text(worker.employeeId.isEmpty
                                  ? '${worker.embeddings.length} angles'
                                  : worker.employeeId),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () =>
                                    widget.store.removeWorker(worker.id),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: _addWorker,
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
