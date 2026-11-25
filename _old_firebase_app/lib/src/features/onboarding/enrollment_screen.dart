import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/services/face_capture_service.dart';

/// Enrollment: capture the face angles, bind the device, arm the local unlock.
///
/// The frames are held in memory and posted straight to `enrollFace`. They are
/// never written to disk or to Storage — the server turns them into a template
/// and drops them, so there is no photo set to leak later.
class EnrollmentScreen extends ConsumerStatefulWidget {
  const EnrollmentScreen({super.key, this.cameraService});

  final FaceCaptureService? cameraService;

  @override
  ConsumerState<EnrollmentScreen> createState() => _EnrollmentScreenState();
}

/// Angles requested, in order. Multiple angles make the template robust enough
/// that an honest employee is not rejected for tilting their head at check-in.
const _angles = <String>[
  'Look straight at the camera',
  'Turn slightly to your left',
  'Turn slightly to your right',
  'Tilt your chin down a little',
  'Tilt your chin up a little',
  'Smile, looking straight ahead',
];

class _EnrollmentScreenState extends ConsumerState<EnrollmentScreen> {
  late final FaceCaptureService _camera = widget.cameraService ?? FaceCaptureService();
  final List<Uint8List> _frames = [];

  bool _ready = false;
  bool _busy = false;
  String? _error;
  // Separate from `_error`, which is fatal (bad camera, compromised device)
  // and replaces the whole screen. A registerDevice/enrollFace failure here
  // should be retryable without losing the captured frames or the buttons.
  String? _finishError;
  String _step = 'Preparing camera…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    // Refuse to bind an identity to hardware we already know is untrustworthy.
    final integrity = await ref.read(deviceServiceProvider).integrity();
    if (integrity.isCompromised) {
      setState(() => _error =
          'This device appears rooted, jailbroken or emulated. Enrollment is blocked.');
      return;
    }
    try {
      await _camera.initialize();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _captureAngle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _frames.add(await _camera.captureStill());
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    setState(() {
      _busy = true;
      _finishError = null;
      _step = 'Registering this device…';
    });
    try {
      final api = ref.read(apiProvider);
      final devices = ref.read(deviceServiceProvider);

      final identity = await devices.identity();
      final integrity = await devices.integrity();
      await api.registerDevice(
        deviceId: identity.deviceId,
        platform: identity.platform,
        model: identity.model,
        compromised: integrity.isCompromised,
      );

      setState(() => _step = 'Creating your face template…');
      await api.enrollFace(_frames);

      // Local biometric is set up last and is a convenience gate only — the
      // server never treats it as proof of identity.
      setState(() => _step = 'Setting up quick unlock…');
      await devices.confirmLocalBiometric(reason: 'Enable quick unlock for TrustPunch');

      // The frames have served their purpose; drop them immediately.
      _frames.clear();

      ref.invalidate(currentEmployeeProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _finishError = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final captured = _frames.length;
    final done = captured >= _angles.length - 1;

    return Scaffold(
      appBar: AppBar(title: const Text('Enrollment')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    key: const Key('enrollment-error'), textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: _ready && _camera.controller != null
                      ? CameraPreview(_camera.controller!)
                      : Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 12),
                              Text(_step),
                            ],
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      if (_finishError != null) ...[
                        Text(
                          _finishError!,
                          key: const Key('enrollment-finish-error'),
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                      ],
                      LinearProgressIndicator(value: captured / _angles.length),
                      const SizedBox(height: 16),
                      Text(
                        captured < _angles.length
                            ? _angles[captured]
                            : 'All angles captured',
                        key: const Key('enrollment-instruction'),
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      Text('$captured of ${_angles.length} captured'),
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const Key('enrollment-capture'),
                        onPressed: _busy || !_ready || captured >= _angles.length
                            ? null
                            : _captureAngle,
                        child: Text(_busy ? 'Working…' : 'Capture this angle'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        key: const Key('enrollment-finish'),
                        onPressed: done && !_busy ? _finish : null,
                        style:
                            OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        child: const Text('Finish enrollment'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
