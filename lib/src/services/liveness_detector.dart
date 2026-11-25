import 'dart:math';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

enum LivenessPrompt { blinkTwice, turnLeft, turnRight }

extension LivenessPromptText on LivenessPrompt {
  String get instruction => switch (this) {
        LivenessPrompt.blinkTwice => 'Blink twice',
        LivenessPrompt.turnLeft => 'Slowly turn your head left',
        LivenessPrompt.turnRight => 'Slowly turn your head right',
      };
}

/// Turns a stream of ML Kit observations into a pass/fail liveness verdict.
///
/// A still photo held to the camera cannot satisfy any of these: each prompt
/// needs a change across frames, not a single flattering reading.
class LivenessDetector {
  LivenessDetector({LivenessPrompt? prompt})
      : prompt = prompt ??
            LivenessPrompt.values[Random().nextInt(LivenessPrompt.values.length)];

  final LivenessPrompt prompt;

  static const _closedThreshold = 0.25;
  static const _openThreshold = 0.7;
  static const _turnDegrees = 20.0;
  static const _requiredFrames = 8;

  int _frames = 0;
  bool _sawFace = false;
  double _maxYaw = 0;
  double _minYaw = 0;
  int _blinks = 0;
  bool _eyesClosed = false;

  bool get sawFace => _sawFace;

  /// Multiple faces means we cannot tell whose face is being measured, so
  /// those frames are dropped rather than averaged together.
  void addFrame(List<Face> faces) {
    _frames++;
    if (faces.length != 1) {
      _sawFace = false;
      return;
    }

    final face = faces.first;
    _sawFace = true;

    final eyeOpen = face.leftEyeOpenProbability;
    if (eyeOpen != null) {
      // A blink is a closed->open transition, not merely a low reading: a
      // half-lidded photo would otherwise register as blinking forever.
      if (eyeOpen < _closedThreshold) {
        _eyesClosed = true;
      } else if (eyeOpen > _openThreshold && _eyesClosed) {
        _eyesClosed = false;
        _blinks++;
      }
    }

    final yaw = face.headEulerAngleY;
    if (yaw != null) {
      if (yaw > _maxYaw) _maxYaw = yaw;
      if (yaw < _minYaw) _minYaw = yaw;
    }
  }

  bool get isSatisfied {
    if (_frames < _requiredFrames) return false;
    return switch (prompt) {
      LivenessPrompt.blinkTwice => _blinks >= 2,
      LivenessPrompt.turnLeft => _minYaw <= -_turnDegrees,
      LivenessPrompt.turnRight => _maxYaw >= _turnDegrees,
    };
  }

  String get hint {
    if (!_sawFace) return 'Hold your face inside the frame';
    return switch (prompt) {
      LivenessPrompt.blinkTwice => 'Blinks detected: $_blinks of 2',
      LivenessPrompt.turnLeft => 'Keep turning left',
      LivenessPrompt.turnRight => 'Keep turning right',
    };
  }
}
