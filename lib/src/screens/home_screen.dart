import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../i18n/phrases.dart';
import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../services/face_recognizer.dart';
import '../services/speech_service.dart';
import '../services/supervisor_lock.dart';
import '../store/attendance_store.dart';
import 'calendar_screen.dart';
import 'leave_screen.dart';
import 'sites_screen.dart';
import 'supervisor_pin.dart';
import 'verify_screen.dart';
import 'workers_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
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
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static final _clock = DateFormat('HH:mm');

  Timer? _ticker;

  String get _lang => widget.store.languageCode;

  @override
  void initState() {
    super.initState();
    // Drives both the wall clock and any running session's hours.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.speech.setLanguage(_lang);
      await widget.speech.refreshAvailable();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.speech.stop();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Opens a screen that changes who or where can punch, after the PIN.
  Future<void> _openProtected(Widget Function() screen) async {
    if (!await requireSupervisor(context, widget.lock, _lang)) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => screen()),
    );
  }

  Future<void> _scan() async {
    final store = widget.store;
    if (store.workers.isEmpty) {
      widget.speech.say(Phrase.registerFaceFirst);
      _snack(t(_lang, T.noWorkers));
      return;
    }
    if (store.sites.isEmpty) {
      widget.speech.say(Phrase.addSiteFirst);
      _snack(t(_lang, T.noSitesYet));
      return;
    }

    final intent = await Navigator.of(context).push<PunchIntent>(
      MaterialPageRoute(
        builder: (_) => VerifyScreen(
          store: store,
          recognizer: widget.recognizer,
          speech: widget.speech,
          restrictTo:
              store.mode == AppMode.individual ? store.activeWorker : null,
        ),
      ),
    );
    if (intent == null || !mounted) return;

    // Re-checked after the camera round trip: the worker's state could have
    // moved on while the verify screen was open.
    if (!store.allowedActions(intent.worker.id).contains(intent.type)) {
      _snack(t(_lang, T.tryAgain));
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
    if (!mounted) return;

    widget.speech.say(switch (intent.type) {
      PunchType.checkIn || PunchType.breakEnd => Phrase.workStarted,
      PunchType.checkOut || PunchType.breakStart => Phrase.workFinished,
    });
    _snack('${intent.worker.name} · ${_clock.format(DateTime.now())}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TrustPunch'),
        actions: [
          IconButton(
            tooltip: 'Workers',
            icon: const Icon(Icons.people),
            onPressed: () => _openProtected(
              () => WorkersScreen(
                store: widget.store,
                lock: widget.lock,
                recognizer: widget.recognizer,
                speech: widget.speech,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Attendance',
            icon: const Icon(Icons.calendar_month),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    CalendarScreen(store: widget.store, lock: widget.lock),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Leave',
            icon: const Icon(Icons.event_busy),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    LeaveScreen(store: widget.store, lock: widget.lock),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Sites',
            icon: const Icon(Icons.business),
            onPressed: () => _openProtected(
              () => SitesScreen(store: widget.store),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final store = widget.store;
          final today = DateTime.now();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _ClockCard(),
              const SizedBox(height: 20),
              if (store.mode == AppMode.individual)
                _IndividualButton(
                  status: store.activeWorker == null
                      ? WorkerStatus.off
                      : store.statusOf(store.activeWorker!.id),
                  lang: _lang,
                  onPressed: _scan,
                )
              else
                _ScanButton(label: t(_lang, T.scanFace), onPressed: _scan),
              const SizedBox(height: 12),
              _ModeBar(store: store, lock: widget.lock, lang: _lang),
              const SizedBox(height: 12),
              _VoiceBar(store: store, speech: widget.speech),
              const SizedBox(height: 20),
              Text(t(_lang, T.today),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (store.workers.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text(t(_lang, T.noWorkers))),
                )
              else
                ...(store.mode == AppMode.individual
                        ? [if (store.activeWorker != null) store.activeWorker!]
                        : store.workers)
                    .map((worker) => _WorkerCard(
                      worker: worker,
                      status: store.statusOf(worker.id),
                      worked: store.workedOn(worker.id, today),
                      onBreakFor: store.breakOn(worker.id, today),
                      bySite: store.workedBySiteOn(worker.id, today),
                      onLeave: store.leaveOn(worker.id, today) != null,
                      flags: store.flagsFor(worker.id, today),
                      lang: _lang,
                    )),
            ],
          );
        },
      ),
    );
  }
}

String formatHours(Duration d) =>
    '${d.inHours}h ${d.inMinutes.remainder(60).toString().padLeft(2, '0')}m';

/// "Warehouse 3h 10m · Head office 4h 05m", largest first.
String formatBySite(Map<String, Duration> bySite) {
  final entries = bySite.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries.map((e) => '${e.key} ${formatHours(e.value)}').join(' · ');
}

/// One button, no choice: the phone cannot know who is walking up until it
/// has looked, so it asks for a face and works everything else out after.
class _ScanButton extends StatelessWidget {
  const _ScanButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF00696D),
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
              const Icon(Icons.face, size: 76, color: Colors.white),
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

/// Individual mode keeps the green-go / red-stop button, because with one
/// known person the phone can say what the next action is before looking.
class _IndividualButton extends StatelessWidget {
  const _IndividualButton({
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

    return Material(
      color: color,
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

/// Switching mode or owner changes whose face the phone accepts, so both sit
/// behind the supervisor PIN like the Workers and Sites screens.
class _ModeBar extends StatefulWidget {
  const _ModeBar({required this.store, required this.lock, required this.lang});

  final AttendanceStore store;
  final SupervisorLock lock;
  final String lang;

  @override
  State<_ModeBar> createState() => _ModeBarState();
}

class _ModeBarState extends State<_ModeBar> {
  /// Bumped when a dropdown change is refused, so the dropdown is rebuilt
  /// showing the owner that is actually stored rather than the one picked.
  int _ownerResets = 0;

  AttendanceStore get store => widget.store;
  String get lang => widget.lang;

  Future<void> _setMode(AppMode mode) async {
    if (mode == store.mode) return;
    if (!await requireSupervisor(context, widget.lock, lang)) return;
    await store.setMode(mode);
  }

  Future<void> _setOwner(String id) async {
    if (id == store.activeWorker?.id) return;
    if (await requireSupervisor(context, widget.lock, lang)) {
      await store.setActiveWorker(id);
    } else if (mounted) {
      setState(() => _ownerResets++);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SegmentedButton<AppMode>(
          segments: [
            ButtonSegment(
              value: AppMode.individual,
              icon: const Icon(Icons.person),
              label: Text(t(lang, T.individualMode)),
            ),
            ButtonSegment(
              value: AppMode.team,
              icon: const Icon(Icons.groups),
              label: Text(t(lang, T.teamMode)),
            ),
          ],
          selected: {store.mode},
          onSelectionChanged: (s) => _setMode(s.first),
        ),
        if (store.mode == AppMode.individual && store.workers.length > 1) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey('owner-${store.activeWorker?.id}-$_ownerResets'),
            initialValue: store.activeWorker?.id,
            decoration: InputDecoration(
              labelText: t(lang, T.thisPhoneBelongsTo),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            items: store.workers
                .map((w) => DropdownMenuItem(value: w.id, child: Text(w.name)))
                .toList(),
            onChanged: (id) {
              if (id != null) _setOwner(id);
            },
          ),
        ],
      ],
    );
  }
}

class _WorkerCard extends StatelessWidget {
  const _WorkerCard({
    required this.worker,
    required this.status,
    required this.worked,
    required this.onBreakFor,
    required this.bySite,
    required this.onLeave,
    required this.flags,
    required this.lang,
  });

  final Worker worker;
  final WorkerStatus status;
  final Duration worked;
  final Duration onBreakFor;
  final Map<String, Duration> bySite;
  final bool onLeave;
  final ShiftFlags flags;
  final String lang;

  @override
  Widget build(BuildContext context) {
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

class _VoiceBar extends StatelessWidget {
  const _VoiceBar({required this.store, required this.speech});

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
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: supportedLanguages.map((language) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
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
        ),
      ],
    );
  }
}

/// Live wall clock. Repainted by the parent's one-second ticker.
class _ClockCard extends StatelessWidget {
  const _ClockCard();

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
