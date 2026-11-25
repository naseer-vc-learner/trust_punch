import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../i18n/phrases.dart';
import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../services/face_recognizer.dart';
import '../services/speech_service.dart';
import '../store/attendance_store.dart';
import 'verify_screen.dart';

// Pieces the worker, kiosk and supervisor home screens share.

String formatHours(Duration d) =>
    '${d.inHours}h ${d.inMinutes.remainder(60).toString().padLeft(2, '0')}m';

/// "Warehouse 3h 10m · Head office 4h 05m", largest first.
String formatBySite(Map<String, Duration> bySite) {
  final entries = bySite.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries.map((e) => '${e.key} ${formatHours(e.value)}').join(' · ');
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Proves who and where, then records the punch.
///
/// [restrictTo] set: personal phone, confirm that one face (1:1).
/// [restrictTo] null: gate phone, find the face among everyone (1:N).
Future<void> runPunch(
  BuildContext context, {
  required AttendanceStore store,
  required FaceRecognizer recognizer,
  required SpeechService speech,
  Worker? restrictTo,
}) async {
  final lang = store.languageCode;
  if (store.workers.isEmpty) {
    speech.say(Phrase.registerFaceFirst);
    showSnack(context, t(lang, T.noWorkers));
    return;
  }
  if (store.sites.isEmpty) {
    speech.say(Phrase.addSiteFirst);
    showSnack(context, t(lang, T.noSitesYet));
    return;
  }

  final intent = await Navigator.of(context).push<PunchIntent>(
    MaterialPageRoute(
      builder: (_) => VerifyScreen(
        store: store,
        recognizer: recognizer,
        speech: speech,
        restrictTo: restrictTo,
      ),
    ),
  );
  if (intent == null || !context.mounted) return;

  // Re-checked after the camera round trip: the worker's state could have
  // moved on while the verify screen was open.
  if (!store.allowedActions(intent.worker.id).contains(intent.type)) {
    showSnack(context, t(lang, T.tryAgain));
    return;
  }

  await store.add(Punch(
    type: intent.type,
    at: DateTime.now(),
    workerId: intent.worker.id,
    employeeId: intent.worker.employeeId,
    workerName: intent.worker.name,
    siteId: intent.site.id,
    siteName: intent.site.name,
    latitude: intent.latitude,
    longitude: intent.longitude,
    distanceMeters: intent.distanceMeters,
  ));
  if (!context.mounted) return;

  speech.say(switch (intent.type) {
    PunchType.checkIn || PunchType.breakEnd => Phrase.workStarted,
    PunchType.checkOut || PunchType.breakStart => Phrase.workFinished,
  });
  showSnack(
    context,
    '${intent.worker.name} · ${DateFormat('HH:mm').format(DateTime.now())}',
  );
}

/// Rebuilds its child every second: drives the wall clock and the live
/// hours of anyone currently on the clock.
class SecondTicker extends StatefulWidget {
  const SecondTicker({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  State<SecondTicker> createState() => _SecondTickerState();
}

class _SecondTickerState extends State<SecondTicker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// The one large button a home screen is built around.
class BigActionButton extends StatelessWidget {
  const BigActionButton({
    super.key,
    required this.color,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onPressed == null ? Colors.grey : color,
      borderRadius: BorderRadius.circular(24),
      elevation: 3,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(24),
        child: SizedBox(
          height: 180,
          width: double.infinity,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 72, color: Colors.white),
              const SizedBox(height: 12),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Live wall clock. Rebuilt by a surrounding [SecondTicker].
class ClockCard extends StatelessWidget {
  const ClockCard({super.key});

  static final _time = DateFormat('HH:mm:ss');
  static final _date = DateFormat('EEEE, d MMMM yyyy');

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Column(
      children: [
        Text(
          _time.format(now),
          style: Theme.of(context).textTheme.displayMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w300,
              ),
        ),
        Text(_date.format(now),
            style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

/// Today's status, hours and flags for one worker.
class WorkerCard extends StatelessWidget {
  const WorkerCard({
    super.key,
    required this.store,
    required this.worker,
  });

  final AttendanceStore store;
  final Worker worker;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final lang = store.languageCode;
    final status = store.statusOf(worker.id);
    final worked = store.workedOn(worker.id, today);
    final onBreakFor = store.breakOn(worker.id, today);
    final bySite = store.workedBySiteOn(worker.id, today);
    final onLeave = store.leaveOn(worker.id, today) != null;
    final flags = store.flagsFor(worker.id, today);

    final scheme = Theme.of(context).colorScheme;
    final (color, icon, label) = switch (status) {
      WorkerStatus.working => (
          scheme.primaryContainer,
          Icons.check_circle,
          t(lang, T.checkedIn)
        ),
      WorkerStatus.onBreak => (
          const Color(0xFFFFE0B2),
          Icons.free_breakfast,
          t(lang, T.onBreak)
        ),
      WorkerStatus.off => (
          scheme.surfaceContainerHighest,
          Icons.pause_circle_outline,
          t(lang, T.notCheckedIn)
        ),
    };

    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(worker.name,
                          style: Theme.of(context).textTheme.titleMedium),
                      if (worker.employeeId.isNotEmpty)
                        Text(worker.employeeId,
                            style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            // Work and break are shown apart on purpose: one total invites the
            // question of whether the break is inside it or not.
            Row(
              children: [
                Expanded(
                  child: _Stat(
                    icon: Icons.work_outline,
                    label: t(lang, T.workedToday),
                    value: formatHours(worked),
                    emphasised: true,
                  ),
                ),
                Expanded(
                  child: _Stat(
                    icon: Icons.free_breakfast,
                    label: t(lang, T.breakTime),
                    value: formatHours(onBreakFor),
                  ),
                ),
              ],
            ),
            if (bySite.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '${t(lang, T.hoursBySite)}: ${formatBySite(bySite)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              children: [
                // "Not working" says nothing new beside "On leave"; but a
                // worker on leave who clocked in anyway keeps both chips.
                if (!(onLeave && status == WorkerStatus.off))
                  Chip(
                    label: Text(label),
                    visualDensity: VisualDensity.compact,
                  ),
                if (onLeave)
                  Chip(
                    avatar: const Icon(Icons.event_busy, size: 18),
                    label: Text(t(lang, T.onLeave)),
                    visualDensity: VisualDensity.compact,
                  ),
                if (flags.late)
                  Chip(
                    label: Text(t(lang, T.lateFlag)),
                    backgroundColor: scheme.errorContainer,
                    visualDensity: VisualDensity.compact,
                  ),
                if (flags.overtime)
                  Chip(
                    label: Text(t(lang, T.overtimeFlag)),
                    backgroundColor: scheme.tertiaryContainer,
                    visualDensity: VisualDensity.compact,
                  ),
                if (flags.short)
                  Chip(
                    label: Text(t(lang, T.shortFlag)),
                    backgroundColor: scheme.secondaryContainer,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.label,
    required this.value,
    this.emphasised = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 4),
            Flexible(
              child: Text(label,
                  style: text.labelMedium, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: emphasised
              ? text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)
              : text.titleLarge,
        ),
      ],
    );
  }
}

/// "Listen again" plus the language chips. Picking a language changes the
/// whole app and speaks the first instruction in it.
class VoiceBar extends StatelessWidget {
  const VoiceBar({super.key, required this.store, required this.speech});

  final AttendanceStore store;
  final SpeechService speech;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        OutlinedButton.icon(
          onPressed: () => speech.say(Phrase.startWork),
          icon: const Icon(Icons.volume_up, size: 28),
          label: Text(t(store.languageCode, T.listenAgain)),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
        ),
        const SizedBox(height: 8),
        LanguageChips(store: store, speech: speech),
      ],
    );
  }
}

class LanguageChips extends StatelessWidget {
  const LanguageChips({super.key, required this.store, required this.speech});

  final AttendanceStore store;
  final SpeechService speech;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: supportedLanguages.map((language) {
          return Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: ChoiceChip(
              selected: language.code == store.languageCode,
              avatar: speech.canSpeak(language.code)
                  ? null
                  : const Icon(Icons.volume_off, size: 18),
              label: Text(language.nativeName),
              onSelected: (_) async {
                await store.setLanguage(language.code);
                await speech.setLanguage(language.code);
                await speech.say(Phrase.startWork);
              },
            ),
          );
        }).toList(),
      ),
    );
  }
}
