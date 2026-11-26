import 'package:flutter/material.dart';

import '../demo/demo_data.dart';
import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../services/face_recognizer.dart';
import '../services/speech_service.dart';
import '../services/supervisor_lock.dart';
import '../store/attendance_store.dart';
import 'approvals_screens.dart';
import 'calendar_screen.dart';
import 'leave_screen.dart';
import 'shared_widgets.dart';
import 'project_screens.dart';
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
          _DemoMenu(store: store),
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
                  _ApprovalTile(
                    icon: Icons.more_time,
                    title: t(lang, T.overtimeApprovals),
                    waiting: store.pendingOvertimeCount,
                    lang: lang,
                    onTap: () => _open(context, OvertimeScreen(store: store)),
                  ),
                  const Divider(height: 1),
                  _ApprovalTile(
                    icon: Icons.edit_calendar,
                    title: t(lang, T.punchCorrections),
                    waiting: store.pendingCorrectionCount,
                    lang: lang,
                    onTap: () =>
                        _open(context, CorrectionsScreen(store: store)),
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
                    leading: const Icon(Icons.apartment),
                    title: Text(t(lang, T.projects)),
                    subtitle: Text(
                      '${store.projects.length} · '
                      '${store.sites.length} ${t(lang, T.workSites).toLowerCase()}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(
                      context,
                      ProjectsScreen(
                        store: store,
                        recognizer: recognizer,
                        speech: speech,
                      ),
                    ),
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

/// A list row for something waiting on the supervisor, with a count badge.
class _ApprovalTile extends StatelessWidget {
  const _ApprovalTile({
    required this.icon,
    required this.title,
    required this.waiting,
    required this.lang,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final int waiting;
  final String lang;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Badge(
          isLabelVisible: waiting > 0,
          label: Text('$waiting'),
          child: Icon(icon),
        ),
        title: Text(title),
        subtitle: waiting > 0
            ? Text(t(lang, T.waitingCount).replaceAll('{n}', '$waiting'))
            : null,
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );
}

/// Loads or removes the demo week (see `demo_data.dart`), after a
/// confirmation. Only reachable inside the supervisor's PIN session.
class _DemoMenu extends StatelessWidget {
  const _DemoMenu({required this.store});

  final AttendanceStore store;

  Future<void> _run(BuildContext context, {required bool load}) async {
    final lang = store.languageCode;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t(lang, load ? T.loadDemo : T.removeDemo)),
        content: Text(t(lang, load ? T.loadDemoConfirm : T.removeDemoConfirm)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t(lang, T.cancel)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t(lang, load ? T.loadDemo : T.removeDemo)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (load) {
      await loadDemoData(store);
    } else {
      await removeDemoData(store);
    }
    if (context.mounted) {
      showSnack(context, t(lang, load ? T.demoLoaded : T.demoRemoved));
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = store.languageCode;
    final loaded = hasDemoData(store);
    return PopupMenuButton<bool>(
      tooltip: t(lang, T.demoData),
      icon: const Icon(Icons.science_outlined),
      onSelected: (load) => _run(context, load: load),
      itemBuilder: (_) => [
        if (!loaded)
          PopupMenuItem(value: true, child: Text(t(lang, T.loadDemo)))
        else
          PopupMenuItem(value: false, child: Text(t(lang, T.removeDemo))),
      ],
    );
  }
}
