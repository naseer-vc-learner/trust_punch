import 'package:flutter/material.dart';

import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../services/face_recognizer.dart';
import '../services/speech_service.dart';
import '../services/supervisor_lock.dart';
import '../store/attendance_store.dart';
import 'approvals_screens.dart' show requestCorrectionFlow;
import 'calendar_screen.dart';
import 'leave_screen.dart';
import 'shared_widgets.dart';

/// One person's own phone: one big button that already knows what the next
/// action is, their own day, their own calendar and their own leave.
///
/// The face check is 1:1 against the phone's owner, which the supervisor
/// sets in the supervisor screens.
class WorkerHome extends StatelessWidget {
  const WorkerHome({
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

  @override
  Widget build(BuildContext context) {
    final lang = store.languageCode;
    final me = store.activeWorker;

    return Scaffold(
      appBar: AppBar(
        title: Text(me?.name ?? t(lang, T.roleWorker)),
        actions: [
          IconButton(
            tooltip: t(lang, T.switchRole),
            icon: const Icon(Icons.switch_account),
            onPressed: onSwitchRole,
          ),
        ],
      ),
      body: SecondTicker(
        builder: (context) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const ClockCard(),
            const SizedBox(height: 20),
            if (me == null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const Icon(Icons.face_retouching_off, size: 56),
                      const SizedBox(height: 12),
                      Text(
                        t(lang, T.askSupervisor),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              _NextActionButton(
                status: store.statusOf(me.id),
                lang: lang,
                onPressed: () => runPunch(
                  context,
                  store: store,
                  recognizer: recognizer,
                  speech: speech,
                  restrictTo: me,
                  // A personal phone: remind its owner at shift end.
                  remindAtShiftEnd: true,
                ),
              ),
              const SizedBox(height: 16),
              WorkerCard(store: store, worker: me),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.calendar_month),
                      label: Text(t(lang, T.myAttendance)),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => CalendarScreen(
                            store: store,
                            lock: lock,
                            onlyWorker: me,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.event_busy),
                      label: Text(t(lang, T.requestLeave)),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => LeaveScreen(
                            store: store,
                            lock: lock,
                            onlyWorker: me,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.edit_calendar),
                label: Text(t(lang, T.fixPunch)),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed: () =>
                    requestCorrectionFlow(context, store, fixedWorker: me),
              ),
            ],
            const SizedBox(height: 16),
            VoiceBar(store: store, speech: speech),
          ],
        ),
      ),
    );
  }
}

/// Green to start, red to finish, orange to come back from a break: with one
/// known person the phone can say what the next action is before looking.
class _NextActionButton extends StatelessWidget {
  const _NextActionButton({
    required this.status,
    required this.lang,
    required this.onPressed,
  });

  final WorkerStatus status;
  final String lang;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = switch (status) {
      WorkerStatus.off => (
          const Color(0xFF2E7D32),
          Icons.login,
          t(lang, T.startWorkBig)
        ),
      WorkerStatus.working => (
          const Color(0xFFC62828),
          Icons.logout,
          t(lang, T.finishWorkBig)
        ),
      WorkerStatus.onBreak => (
          const Color(0xFFEF6C00),
          Icons.work_outline,
          t(lang, T.endBreak)
        ),
    };
    return BigActionButton(
      color: color,
      icon: icon,
      label: label,
      onPressed: onPressed,
    );
  }
}
