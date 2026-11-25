import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../i18n/phrases.dart';
import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../services/face_capture_service.dart';
import '../services/face_recognizer.dart';
import '../services/integrity_service.dart';
import '../services/liveness_detector.dart';
import '../services/location_service.dart';
import '../services/speech_service.dart';
import '../store/attendance_store.dart';

/// What the caller should record, once everything has been proven.
class PunchIntent {
  const PunchIntent({
    required this.worker,
    required this.site,
    required this.type,
    required this.latitude,
    required this.longitude,
    required this.distanceMeters,
  });

  final Worker worker;
  final Site site;
  final PunchType type;
  final double latitude;
  final double longitude;
  final double distanceMeters;
}

enum _Stage { checking, blocked, liveness, matching, choosing }

/// Proves four things in order: the phone is trustworthy, you are at a site,
/// you are a live person, and you are someone this phone knows.
class VerifyScreen extends StatefulWidget {
  const VerifyScreen({
    super.key,
    required this.store,
    required this.recognizer,
    required this.speech,
    this.restrictTo,
  });

  final AttendanceStore store;
  final FaceRecognizer recognizer;
  final SpeechService speech;

  /// Individual mode: confirm this one person rather than search the roster.
  /// Matching against one face is far safer than picking from many.
  final Worker? restrictTo;

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  final _location = LocationService();
  final _integrity = IntegrityService();
  final _camera = FaceCaptureService();
  LivenessDetector _detector = LivenessDetector();

  _Stage _stage = _Stage.checking;
  String _message = '';
  String _hint = '';
  Site? _site;
  double _distance = 0;
  LocationFix? _fix;
  Worker? _worker;
  bool _passed = false;

  String get _lang => widget.store.languageCode;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  void _block(String message, [Phrase? spoken]) {
    if (spoken != null) widget.speech.say(spoken);
    if (mounted) {
      setState(() {
        _stage = _Stage.blocked;
        _message = message;
      });
    }
  }

  Future<void> _run() async {
    setState(() {
      _stage = _Stage.checking;
      _message = '';
    });
    widget.speech.say(Phrase.findingLocation);

    try {
      if (await _integrity.isCompromised()) {
        _block(t(_lang, T.deviceNotSafe));
        return;
      }

      final fix = await _location.currentFix();
      if (!mounted) return;
      _fix = fix;

      // A spoofed fix would put someone at the gate from home, which defeats
      // the geofence entirely — so it is refused outright rather than flagged.
      if (fix.isMocked) {
        _block(t(_lang, T.fakeLocation));
        return;
      }

      if (!fix.isPrecise) {
        _block(
          '${t(_lang, T.weakLocation)} (±${fix.accuracyMeters.round()} m)',
          Phrase.weakLocation,
        );
        return;
      }

      final ranked = rankSites(fix, widget.store.sites);
      if (ranked.isEmpty) {
        _block(t(_lang, T.noSitesYet));
        return;
      }

      final nearest = ranked.first;
      _site = nearest.site;
      _distance = nearest.meters;

      if (!nearest.inRange) {
        _block(
          '${nearest.site.name} — ${nearest.meters.round()} m',
          Phrase.tooFar,
        );
        return;
      }

      await _startLiveness();
    } catch (e) {
      _block('$e');
    }
  }

  Future<void> _startLiveness() async {
    _detector = LivenessDetector();
    _passed = false;
    setState(() {
      _stage = _Stage.liveness;
      _hint = '';
    });

    await widget.recognizer.load();
    await _camera.initialize();
    if (!mounted) return;
    setState(() => _hint = _detector.hint);
    widget.speech.say(switch (_detector.prompt) {
      LivenessPrompt.blinkTwice => Phrase.blinkTwice,
      LivenessPrompt.turnLeft => Phrase.turnLeft,
      LivenessPrompt.turnRight => Phrase.turnRight,
    });

    await _camera.streamFaces((faces) {
      if (_passed || !mounted) return;
      _detector.addFrame(faces);

      if (_detector.isSatisfied) {
        _passed = true;
        _identify();
        return;
      }
      final hint = _detector.hint;
      if (hint != _hint) setState(() => _hint = hint);
    });
  }

  Future<void> _identify() async {
    setState(() => _stage = _Stage.matching);
    widget.speech.say(Phrase.checkingFace);

    try {
      final path = await _camera.capturePhoto();
      final embedding = await widget.recognizer.embedFromPhoto(path);
      if (!mounted) return;

      if (embedding == null) {
        _block(t(_lang, T.noFaceFound), Phrase.faceNotMatched);
        return;
      }

      final candidates = widget.restrictTo != null
          ? [widget.restrictTo!]
          : widget.store.workers;
      final match = widget.recognizer.identify(embedding, candidates);
      if (match == null) {
        _block(t(_lang, T.notRecognised), Phrase.faceNotMatched);
        return;
      }
      _worker = match.worker;

      // An open session has to close at the site it opened at, or the hours
      // land against a site the person never worked.
      final open = widget.store.openSiteFor(match.worker.id);
      if (open != null && open.id != _site!.id) {
        _block('${match.worker.name}: ${open.name}', Phrase.tooFar);
        return;
      }

      final actions = widget.store.allowedActions(match.worker.id);
      if (actions.length == 1) {
        _finish(actions.first);
        return;
      }
      setState(() => _stage = _Stage.choosing);
    } catch (e) {
      _block('$e');
    }
  }

  void _finish(PunchType type) {
    final worker = _worker;
    final site = _site;
    final fix = _fix;
    if (worker == null || site == null || fix == null) return;

    Navigator.of(context).pop(PunchIntent(
      worker: worker,
      site: site,
      type: type,
      latitude: fix.latitude,
      longitude: fix.longitude,
      distanceMeters: _distance,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t(_lang, T.scanFace))),
      body: switch (_stage) {
        _Stage.checking => _Centered(
            icon: Icons.my_location,
            title: t(_lang, T.findingSite),
          ),
        _Stage.matching => _Centered(
            icon: Icons.face_retouching_natural,
            title: t(_lang, T.matchingFace),
          ),
        _Stage.blocked => _Centered(
            icon: Icons.block,
            title: t(_lang, T.couldNotVerify),
            detail: _message,
            retryLabel: t(_lang, T.tryAgain),
            onRetry: _run,
          ),
        _Stage.liveness => _buildLiveness(),
        _Stage.choosing => _buildChoice(),
      },
    );
  }

  Widget _buildLiveness() {
    final controller = _camera.controller;
    return Column(
      children: [
        Expanded(
          child: _camera.isReady && controller != null
              ? CameraPreview(controller)
              : const Center(child: CircularProgressIndicator()),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Column(
            children: [
              Text(
                t(_lang, switch (_detector.prompt) {
                  LivenessPrompt.blinkTwice => T.lookStraight,
                  LivenessPrompt.turnLeft => T.turnLeftSlight,
                  LivenessPrompt.turnRight => T.turnRightSlight,
                }),
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(_hint, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Chip(
                avatar: const Icon(Icons.place, size: 18),
                label: Text('${_site?.name ?? ''} · ${_distance.round()} m'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Only reached when someone on the clock could either stop for a break or
  /// finish for the day — every other state has one legal move and is taken
  /// without asking.
  Widget _buildChoice() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.how_to_reg, size: 64),
          const SizedBox(height: 12),
          Text(
            _worker?.name ?? '',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 4),
          Text(t(_lang, T.whatNext)),
          const SizedBox(height: 32),
          _ChoiceButton(
            color: const Color(0xFFC62828),
            icon: Icons.logout,
            label: t(_lang, T.finishWorkBig),
            onPressed: () => _finish(PunchType.checkOut),
          ),
          const SizedBox(height: 16),
          _ChoiceButton(
            color: const Color(0xFFEF6C00),
            icon: Icons.free_breakfast,
            label: t(_lang, T.takeBreak),
            onPressed: () => _finish(PunchType.breakStart),
          ),
        ],
      ),
    );
  }
}

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({
    required this.color,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 96,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 36),
        label: Text(
          label,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        style: FilledButton.styleFrom(backgroundColor: color),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({
    required this.icon,
    required this.title,
    this.detail,
    this.onRetry,
    this.retryLabel,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onRetry;
  final String? retryLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            if (detail != null && detail!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(detail!, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 24),
            if (onRetry == null)
              const CircularProgressIndicator()
            else
              FilledButton(
                onPressed: onRetry,
                child: Text(retryLabel ?? 'Try again'),
              ),
          ],
        ),
      ),
    );
  }
}
