import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/services/face_capture_service.dart';
import '../result/result_screen.dart';
import 'capture_controller.dart';

/// Live capture. Camera only — there is no gallery import anywhere in the app,
/// because a file the employee chose is not evidence of anything.
class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({
    super.key,
    required this.type,
    this.direction = AttendanceDirection.checkIn,
    this.siteId,
    this.pingId,
    this.cameraService,
  });

  final AttendanceType type;

  /// Which edge of the working day this capture records. Every direction runs
  /// the identical verification — leaving is proved exactly as arriving is.
  final AttendanceDirection direction;
  final String? siteId;

  /// Set when this capture answers a WFH presence ping.
  final String? pingId;

  /// Injectable for tests; production builds construct the real service.
  final FaceCaptureService? cameraService;

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen> {
  late final FaceCaptureService _camera = widget.cameraService ?? FaceCaptureService();
  bool _cameraReady = false;
  bool _submitted = false;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  Future<void> _begin() async {
    await ref.read(captureControllerProvider.notifier).start();
    if (!mounted) return;
    try {
      await _camera.initialize();
      if (!mounted) return;
      setState(() => _cameraReady = true);
      await _camera.streamFaces((faces) {
        ref.read(captureControllerProvider.notifier).detector?.addFrame(faces);
        ref.read(captureControllerProvider.notifier).onFrameAnalysed();
        _maybeCapture();
      });
    } catch (e) {
      if (mounted) setState(() => _cameraError = '$e');
    }
  }

  /// Fires the still the moment liveness is satisfied — waiting for a tap would
  /// let the employee take the photo at a different moment than the challenge.
  Future<void> _maybeCapture() async {
    if (_submitted) return;
    final state = ref.read(captureControllerProvider);
    if (state is! CaptureAwaitingLiveness || !state.satisfied) return;

    _submitted = true;
    try {
      final selfie = await _camera.captureStill();
      await ref.read(captureControllerProvider.notifier).submit(
            selfie: selfie,
            type: widget.type,
            direction: widget.direction,
            siteId: widget.siteId,
          );
    } catch (e) {
      if (mounted) setState(() => _cameraError = '$e');
    }
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<CaptureState>(captureControllerProvider, (_, next) {
      if (next is CaptureComplete) {
        _goToResult(ResultScreen(outcome: next.outcome, pingId: widget.pingId));
      } else if (next is CaptureQueued) {
        _goToResult(const ResultScreen.queued());
      }
    });

    final state = ref.watch(captureControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.direction.label),
      ),
      body: switch (state) {
        CaptureFailed(:final message, :final blocking) =>
          _ErrorView(message: message, canRetry: !blocking, onRetry: _restart),
        CaptureSubmitting() => const _BusyView(label: 'Verifying with the server…'),
        CapturePreparing() => const _BusyView(label: 'Requesting a verification challenge…'),
        _ when _cameraError != null =>
          _ErrorView(message: _cameraError!, canRetry: true, onRetry: _restart),
        CaptureAwaitingLiveness(:final challenge, :final hint, :final satisfied) =>
          _LivenessView(
            camera: _camera,
            ready: _cameraReady,
            instruction: challenge.instruction,
            hint: hint,
            satisfied: satisfied,
          ),
        _ => const _BusyView(label: 'Starting camera…'),
      },
    );
  }

  void _goToResult(Widget screen) {
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _restart() async {
    setState(() {
      _cameraError = null;
      _submitted = false;
    });
    ref.read(captureControllerProvider.notifier).reset();
    await _begin();
  }
}

class _LivenessView extends StatelessWidget {
  const _LivenessView({
    required this.camera,
    required this.ready,
    required this.instruction,
    required this.hint,
    required this.satisfied,
  });

  final FaceCaptureService camera;
  final bool ready;
  final String instruction;
  final String hint;
  final bool satisfied;

  @override
  Widget build(BuildContext context) {
    final controller = camera.controller;
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (ready && controller != null)
                CameraPreview(controller)
              else
                const ColoredBox(
                  color: Colors.black12,
                  child: Center(child: CircularProgressIndicator()),
                ),
              Center(
                child: Container(
                  width: 260,
                  height: 320,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: satisfied ? const Color(0xFF2E7D32) : Colors.white70,
                      width: 3,
                    ),
                    borderRadius: BorderRadius.circular(160),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Text(
                instruction,
                key: const Key('liveness-instruction'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(hint, key: const Key('liveness-hint')),
              const SizedBox(height: 12),
              if (satisfied)
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle, color: Color(0xFF2E7D32)),
                    SizedBox(width: 8),
                    Text('Hold still — capturing'),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BusyView extends StatelessWidget {
  const _BusyView({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(label),
          ],
        ),
      );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    required this.canRetry,
    required this.onRetry,
  });

  final String message;
  final bool canRetry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text(message, key: const Key('capture-error'), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (canRetry)
                FilledButton(onPressed: onRetry, child: const Text('Try again'))
              else
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back'),
                ),
            ],
          ),
        ),
      );
}
