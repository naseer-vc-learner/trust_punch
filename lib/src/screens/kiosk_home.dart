import 'package:flutter/material.dart';

import '../i18n/ui_text.dart';
import '../services/face_recognizer.dart';
import '../services/speech_service.dart';
import '../store/attendance_store.dart';
import 'approvals_screens.dart' show requestCorrectionFlow;
import 'leave_screen.dart';
import 'shared_widgets.dart';

/// The shared tablet at a site gate. One button: the phone cannot know who
/// is walking up until it has looked, so it asks for a face (1:N) and works
/// everything else out after.
///
/// Nothing here changes setup, and the leave list is not shown — a gate
/// screen anyone can read is no place for other people's sick-leave reasons.
class KioskHome extends StatelessWidget {
  const KioskHome({
    super.key,
    required this.store,
    required this.recognizer,
    required this.speech,
    required this.onSwitchRole,
  });

  final AttendanceStore store;
  final FaceRecognizer recognizer;
  final SpeechService speech;
  final VoidCallback onSwitchRole;

  @override
  Widget build(BuildContext context) {
    final lang = store.languageCode;

    return Scaffold(
      appBar: AppBar(
        title: Text(t(lang, T.roleKiosk)),
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
            BigActionButton(
              color: const Color(0xFF00696D),
              icon: Icons.face,
              label: t(lang, T.scanFace),
              onPressed: () => runPunch(
                context,
                store: store,
                recognizer: recognizer,
                speech: speech,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_busy),
              label: Text(t(lang, T.requestLeave)),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: () => requestLeaveFlow(context, store),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.edit_calendar),
              label: Text(t(lang, T.fixPunch)),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: () => requestCorrectionFlow(context, store),
            ),
            const SizedBox(height: 12),
            VoiceBar(store: store, speech: speech),
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
