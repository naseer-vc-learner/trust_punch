import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models/models.dart';
import '../../data/repositories/attendance_repository.dart';
import '../../data/services/liveness_detector.dart';
import '../../data/services/location_service.dart';

/// The capture flow, as an explicit state machine.
///
/// Note what is missing: there is no state the controller can enter that means
/// "approved" without a `CheckInOutcome` from the server. `Queued` is its own
/// state precisely so the UI cannot accidentally render an unconfirmed capture
/// as a successful one.
sealed class CaptureState {
  const CaptureState();
}

class CaptureIdle extends CaptureState {
  const CaptureIdle();
}

class CapturePreparing extends CaptureState {
  const CapturePreparing();
}

/// Camera is live, the employee is performing the server-issued prompt.
class CaptureAwaitingLiveness extends CaptureState {
  const CaptureAwaitingLiveness({
    required this.challenge,
    required this.hint,
    required this.satisfied,
  });

  final LivenessChallenge challenge;
  final String hint;
  final bool satisfied;
}

class CaptureSubmitting extends CaptureState {
  const CaptureSubmitting();
}

class CaptureComplete extends CaptureState {
  const CaptureComplete(this.outcome);
  final CheckInOutcome outcome;
}

/// Captured but not yet judged. Deliberately not a success state.
class CaptureQueued extends CaptureState {
  const CaptureQueued();
}

class CaptureFailed extends CaptureState {
  const CaptureFailed(this.message, {this.blocking = false});

  final String message;

  /// True when retrying cannot help (rooted device, permission refused).
  final bool blocking;
}

class CaptureController extends StateNotifier<CaptureState> {
  CaptureController(this._repository) : super(const CaptureIdle());

  final AttendanceRepository _repository;

  LivenessDetector? _detector;
  LivenessChallenge? _challenge;

  LivenessDetector? get detector => _detector;

  /// Step 1: ask the server which liveness action to perform.
  ///
  /// The prompt must come from the server; a locally chosen one would be
  /// predictable, and a predictable prompt can be pre-recorded.
  Future<void> start() async {
    state = const CapturePreparing();
    try {
      final challenge = await _repository.requestChallenge();
      _challenge = challenge;
      _detector = LivenessDetector(prompt: challenge.prompts.first);
      state = CaptureAwaitingLiveness(
        challenge: challenge,
        hint: 'Position your face inside the circle',
        satisfied: false,
      );
    } catch (e) {
      state = CaptureFailed('Could not start verification: $e');
    }
  }

  /// Step 2: called for every analysed camera frame.
  void onFrameAnalysed() {
    final detector = _detector;
    final challenge = _challenge;
    if (detector == null || challenge == null) return;
    if (state is! CaptureAwaitingLiveness) return;

    if (challenge.isExpired) {
      state = const CaptureFailed('The verification timed out. Please start again.');
      return;
    }

    state = CaptureAwaitingLiveness(
      challenge: challenge,
      hint: detector.progressHint,
      satisfied: detector.isSatisfied,
    );
  }

  /// Step 3: submit the still plus the raw evidence.
  Future<void> submit({
    required Uint8List selfie,
    required AttendanceType type,
    required AttendanceDirection direction,
    String? siteId,
  }) async {
    final detector = _detector;
    final challenge = _challenge;
    if (detector == null || challenge == null) {
      state = const CaptureFailed('Verification was not started.');
      return;
    }

    state = const CaptureSubmitting();
    try {
      final outcome = await _repository.submit(
        type: type,
        direction: direction,
        selfie: selfie,
        challengeId: challenge.challengeId,
        liveness: detector.toEvidence(),
        siteId: siteId,
      );
      state = outcome == null ? const CaptureQueued() : CaptureComplete(outcome);
    } on CompromisedDeviceException catch (e) {
      state = CaptureFailed(e.toString(), blocking: true);
    } on LocationDenied catch (e) {
      state = CaptureFailed(e.message, blocking: true);
    } catch (e) {
      state = CaptureFailed('$e');
    }
  }

  void reset() {
    _detector?.reset();
    _detector = null;
    _challenge = null;
    state = const CaptureIdle();
  }
}

final captureControllerProvider =
    StateNotifierProvider.autoDispose<CaptureController, CaptureState>(
  (ref) => CaptureController(ref.watch(attendanceRepositoryProvider)),
);
