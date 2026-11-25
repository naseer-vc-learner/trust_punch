import 'package:flutter/material.dart';

import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../services/face_recognizer.dart';
import '../services/speech_service.dart';
import '../services/supervisor_lock.dart';
import '../store/attendance_store.dart';
import 'calendar_screen.dart';
import 'leave_screen.dart';
import 'shared_widgets.dart';
import 'sites_screen.dart';
import 'workers_screen.dart';

/// Everything that is not punching: who is on site now, leave waiting for a
/// decision, the attendance calendar, and setup.
///
/// Reached only through the PIN. The session it opens means the screens
/// below do not ask again; "Change user" (or two minutes in the background)
/// ends it.
class SupervisorHome extends StatelessWidget {
  const SupervisorHome({
    super.key,
    required this.store,
    required this.lock,
    required this.recognizer,
    required this.speech,
    required this.onSwitchRole,
  });

  final AttendanceStore store;
  final SupervisorLock lock;
  final FaceRecognizer recognizer;
  final SpeechService speech;
  final VoidCallback onSwitchRole;

  void _open(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final lang = store.languageCode;
    final pending = store.pendingLeaveCount;

    return Scaffold(
      appBar: AppBar(
        title: Text(t(lang, T.roleSupervisor)),
        actions: [
          IconButton(
            tooltip: t(lang, T.switchRole),
            icon: const Icon(Icons.logout),
            onPressed: onSwitchRole,
          ),
        ],
      ),
      body: SecondTicker(
        builder: (context) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _OnSiteBoard(store: store),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: Badge(
                      isLabelVisible: pending > 0,
                      label: Text('$pending'),
                      child: const Icon(Icons.event_busy),
                    ),
                    title: Text(t(lang, T.leaveApprovals)),
                    subtitle: pending > 0
                        ? Text(t(lang, T.waitingCount)
                            .replaceAll('{n}', '$pending'))
                        : null,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(
                      context,
                      LeaveScreen(store: store, lock: lock, canDecide: true),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.calendar_month),
                    title: Text(t(lang, T.attendance)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(
                      context,
                      CalendarScreen(store: store, lock: lock, canDelete: true),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.people),
                    title: Text(t(lang, T.workers)),
                    subtitle: Text('${store.workers.length}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(
                      context,
                      WorkersScreen(
                        store: store,
                        lock: lock,
                        recognizer: recognizer,
                        speech: speech,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.business),
                    title: Text(t(lang, T.workSites)),
                    subtitle: Text('${store.sites.length}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, SitesScreen(store: store)),
                  ),
                ],
              ),
            ),
            if (store.workers.isNotEmpty) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey('owner-${store.activeWorker?.id}'),
                initialValue: store.activeWorker?.id,
                decoration: InputDecoration(
                  labelText: t(lang, T.thisPhoneBelongsTo),
                  helperText: t(lang, T.personalPhoneHelp),
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                ),
                items: store.workers
                    .map((w) =>
                        DropdownMenuItem(value: w.id, child: Text(w.name)))
                    .toList(),
                onChanged: (id) {
                  if (id != null) store.setActiveWorker(id);
                },
              ),
            ],
            const SizedBox(height: 20),
            Text(t(lang, T.today),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (store.workers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text(t(lang, T.noWorkers))),
              )
            else
              for (final worker in store.workers)
                WorkerCard(store: store, worker: worker),
          ],
        ),
      ),
    );
  }
}

/// Four numbers that answer "who is where" at a glance.
class _OnSiteBoard extends StatelessWidget {
  const _OnSiteBoard({required this.store});

  final AttendanceStore store;

  @override
  Widget build(BuildContext context) {
    final lang = store.languageCode;
    final today = DateTime.now();
    var working = 0, onBreak = 0, onLeave = 0, notIn = 0;
    for (final worker in store.workers) {
      switch (store.statusOf(worker.id)) {
        case WorkerStatus.working:
          working++;
        case WorkerStatus.onBreak:
          onBreak++;
        case WorkerStatus.off:
          if (store.leaveOn(worker.id, today) != null) {
            onLeave++;
          } else {
            notIn++;
          }
      }
    }

    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t(lang, T.onSiteNow),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                _Count(value: working, label: t(lang, T.checkedIn)),
                _Count(value: onBreak, label: t(lang, T.onBreak)),
                _Count(value: onLeave, label: t(lang, T.onLeave)),
                _Count(value: notIn, label: t(lang, T.notIn)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        children: [
          Text('$value',
              style: text.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
          Text(label, style: text.labelMedium, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
