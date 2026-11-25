import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../models/models.dart';

/// Accumulates ML Kit face observations into the evidence bundle the server
/// re-checks.
///
/// Pure and framework-free on purpose: the interesting logic (did a blink
/// actually happen, did the head really turn) is unit tested without a camera.
/// It reports what was *observed*; whether that satisfies the challenge is the
/// server's call, and the server re-derives it from the same raw numbers.
class LivenessDetector {
  LivenessDetector({required this.prompt});

  /// The single server-issued prompt this session must satisfy.
  final String prompt;

  int _frames = 0;
  bool _sawFace = false;
  double _maxEyeOpen = 0;
  double _minEyeOpen = 1;
  double _maxYaw = 0;
  double _minYaw = 0;
  int _blinks = 0;
  bool _eyesCurrentlyClosed = false;

  static const _closedThreshold = 0.25;
  static const _openThreshold = 0.7;
  static const _turnDegrees = 20.0;
  static const requiredFrames = 12;

  int get framesAnalysed => _frames;
  int get blinkCount => _blinks;
  bool get sawFace => _sawFace;

  /// Feed one detection result. Multiple faces means we cannot tell whose face
  /// we are measuring, so those frames are ignored rather than averaged.
  void addFrame(List<Face> faces) {
    _frames++;
    if (faces.length != 1) return;

    final face = faces.first;
    _sawFace = true;

    final eyeOpen = face.leftEyeOpenProbability;
    if (eyeOpen != null) {
      if (eyeOpen > _maxEyeOpen) _maxEyeOpen = eyeOpen;
      if (eyeOpen < _minEyeOpen) _minEyeOpen = eyeOpen;

      // A blink is a closed->open transition, not merely a low reading; a
      // half-lidded photo would otherwise register as blinking forever.
      if (eyeOpen < _closedThreshold) {
        _eyesCurrentlyClosed = true;
      } else if (eyeOpen > _openThreshold && _eyesCurrentlyClosed) {
        _eyesCurrentlyClosed = false;
        _blinks++;
      }
    }

    final yaw = face.headEulerAngleY;
    if (yaw != null) {
      if (yaw > _maxYaw) _maxYaw = yaw;
      if (yaw < _minYaw) _minYaw = yaw;
    }
  }

  /// True once the prompt has been satisfied and enough frames were seen.
  bool get isSatisfied {
    if (!_sawFace || _frames < requiredFrames) return false;
    return switch (prompt) {
      'blink_twice' => _blinks >= 2,
      'blink_once' => _blinks >= 1,
      'turn_head_left' => _minYaw <= -_turnDegrees,
      'turn_head_right' => _maxYaw >= _turnDegrees,
      'look_straight_then_left' => (_maxYaw - _minYaw) >= _turnDegrees,
      _ => false,
    };
  }

  /// Live coaching text, so the employee is not left guessing why it is stuck.
  String get progressHint {
    if (!_sawFace) return 'Position your face inside the circle';
    return switch (prompt) {
      'blink_twice' => 'Blinks detected: $_blinks of 2',
      'blink_once' => 'Blinks detected: $_blinks of 1',
      'turn_head_left' => _minYaw <= -_turnDegrees ? 'Done' : 'Keep turning left',
      'turn_head_right' => _maxYaw >= _turnDegrees ? 'Done' : 'Keep turning right',
      _ => isSatisfied ? 'Done' : 'Follow the prompt',
    };
  }

  LivenessEvidence toEvidence() => LivenessEvidence(
        completedActions: isSatisfied ? [prompt] : const [],
        framesAnalysed: _frames,
        maxLeftEyeOpenProb: _maxEyeOpen,
        minLeftEyeOpenProb: _minEyeOpen,
        maxHeadEulerAngleY: _maxYaw,
        minHeadEulerAngleY: _minYaw,
        faceDetected: _sawFace,
      );

  void reset() {
    _frames = 0;
    _sawFace = false;
    _maxEyeOpen = 0;
    _minEyeOpen = 1;
    _maxYaw = 0;
    _minYaw = 0;
    _blinks = 0;
    _eyesCurrentlyClosed = false;
  }
}
