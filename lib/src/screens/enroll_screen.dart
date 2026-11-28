import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../i18n/phrases.dart';
import '../i18n/ui_text.dart';
import '../services/face_capture_service.dart';
import '../services/face_recognizer.dart';
import '../services/speech_service.dart';

/// The angles enrolled, in order.
///
/// A 2D embedding only matches well near the pose it was captured at, so a
/// small spread around frontal is what lets an honest head turn still match.
const _angles = <T>[
  T.lookStraight,
  T.turnLeftSlight,
  T.turnRightSlight,
];

class EnrollScreen extends StatefulWidget {
  const EnrollScreen({
    super.key,
    required this.recognizer,
    required this.speech,
    required this.lang,
  });

  final FaceRecognizer recognizer;
  final SpeechService speech;
  final String lang;

  @override
  State<EnrollScreen> createState() => _EnrollScreenState();
}

class _EnrollScreenState extends State<EnrollScreen> {
  final _camera = FaceCaptureService();
  final _embeddings = <List<double>>[];

  bool _ready = false;
  bool _busy = false;
  String? _fatal;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await widget.recognizer.load();
      await _camera.initialize();
      if (mounted) setState(() => _ready = true);
      widget.speech.say(Phrase.lookAtCamera);
    } catch (e) {
      if (mounted) setState(() => _fatal = '$e');
    }
  }

  Future<void> _captureAngle() async {
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final path = await _camera.capturePhoto();
      final List<double>? embedding;
      try {
        embedding = await widget.recognizer.embedFromPhoto(path);
      } finally {
        // Enrolment keeps only the embedding, never the photo.
        await FaceRecognizer.discardPhoto(path);
      }

      if (embedding == null) {
        setState(() => _notice = t(widget.lang, T.noFaceFound));
        return;
      }
      _embeddings.add(embedding);

      if (_embeddings.length >= _angles.length) {
        if (mounted) Navigator.of(context).pop(_embeddings);
        return;
      }
      setState(() {});
    } catch (e) {
      setState(() => _notice = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final captured = _embeddings.length;

    return Scaffold(
      appBar: AppBar(title: Text(t(widget.lang, T.registerYourFace))),
      body: _fatal != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_fatal!, textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: _ready && _camera.controller != null
                      ? CameraPreview(_camera.controller!)
                      : const Center(child: CircularProgressIndicator()),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      if (_notice != null) ...[
                        Text(
                          _notice!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                      ],
                      LinearProgressIndicator(
                        value: captured / _angles.length,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        t(widget.lang,
                            _angles[captured.clamp(0, _angles.length - 1)]),
                        style: Theme.of(context).textTheme.titleLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text('$captured of ${_angles.length} captured'),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _busy || !_ready ? null : _captureAngle,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
                        ),
                        child: Text(t(widget.lang,
                            _busy ? T.working : T.captureThisAngle)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
