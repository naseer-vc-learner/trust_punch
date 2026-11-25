import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';

/// A check-in captured while offline, waiting for the server to judge it.
///
/// It carries the signals, not a verdict. Nothing in this class can mark
/// attendance as approved — that word only ever comes back from the server.
class QueuedCheckIn {
  const QueuedCheckIn({
    required this.clientNonce,
    required this.type,
    required this.direction,
    required this.capturedAt,
    required this.selfieBase64,
    required this.deviceId,
    required this.challengeId,
    required this.liveness,
    this.siteId,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.isFromMockProvider = false,
    this.deviceCompromised = false,
    this.attempts = 0,
  });

  final String clientNonce;
  final AttendanceType type;
  final AttendanceDirection direction;
  final DateTime capturedAt;
  final String selfieBase64;
  final String deviceId;
  final String challengeId;
  final LivenessEvidence liveness;
  final String? siteId;
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final bool isFromMockProvider;
  final bool deviceCompromised;
  final int attempts;

  Uint8List get selfieBytes => base64Decode(selfieBase64);

  /// Liveness challenges expire in ~90s, so a queued capture cannot be
  /// submitted later and pass. The employee is told to re-capture instead of
  /// being left with a queue item that can only ever be rejected.
  bool get isStale =>
      DateTime.now().difference(capturedAt) > const Duration(minutes: 2);

  QueuedCheckIn withAttempt() => QueuedCheckIn(
        clientNonce: clientNonce,
        type: type,
        direction: direction,
        capturedAt: capturedAt,
        selfieBase64: selfieBase64,
        deviceId: deviceId,
        challengeId: challengeId,
        liveness: liveness,
        siteId: siteId,
        latitude: latitude,
        longitude: longitude,
        accuracyMeters: accuracyMeters,
        isFromMockProvider: isFromMockProvider,
        deviceCompromised: deviceCompromised,
        attempts: attempts + 1,
      );

  Map<String, dynamic> toJson() => {
        'clientNonce': clientNonce,
        'type': type.code,
        'direction': direction.code,
        'capturedAt': capturedAt.toIso8601String(),
        'selfieBase64': selfieBase64,
        'deviceId': deviceId,
        'challengeId': challengeId,
        'liveness': liveness.toMap(),
        'siteId': ?siteId,
        'latitude': ?latitude,
        'longitude': ?longitude,
        'accuracyMeters': ?accuracyMeters,
        'isFromMockProvider': isFromMockProvider,
        'deviceCompromised': deviceCompromised,
        'attempts': attempts,
      };

  factory QueuedCheckIn.fromJson(Map<String, dynamic> json) {
    final liveness = Map<String, dynamic>.from(json['liveness'] as Map);
    return QueuedCheckIn(
      clientNonce: json['clientNonce'] as String,
      type: AttendanceType.fromCode(json['type'] as String?),
      direction: AttendanceDirection.fromCode(json['direction'] as String?),
      capturedAt: DateTime.parse(json['capturedAt'] as String),
      selfieBase64: json['selfieBase64'] as String,
      deviceId: json['deviceId'] as String,
      challengeId: json['challengeId'] as String,
      liveness: LivenessEvidence(
        completedActions:
            (liveness['completedActions'] as List<dynamic>? ?? const []).cast<String>(),
        framesAnalysed: (liveness['framesAnalysed'] as num?)?.toInt() ?? 0,
        maxLeftEyeOpenProb: (liveness['maxLeftEyeOpenProb'] as num?)?.toDouble() ?? 0,
        minLeftEyeOpenProb: (liveness['minLeftEyeOpenProb'] as num?)?.toDouble() ?? 1,
        maxHeadEulerAngleY: (liveness['maxHeadEulerAngleY'] as num?)?.toDouble() ?? 0,
        minHeadEulerAngleY: (liveness['minHeadEulerAngleY'] as num?)?.toDouble() ?? 0,
        faceDetected: liveness['faceDetected'] as bool? ?? false,
      ),
      siteId: json['siteId'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      accuracyMeters: (json['accuracyMeters'] as num?)?.toDouble(),
      isFromMockProvider: json['isFromMockProvider'] as bool? ?? false,
      deviceCompromised: json['deviceCompromised'] as bool? ?? false,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Persists unconfirmed captures in encrypted storage.
///
/// Encrypted because the payload contains a selfie and a location — the same
/// data we refuse to leave lying around server-side.
class OfflineQueue {
  OfflineQueue({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'trustpunch.pending_checkins';
  static const maxAttempts = 3;

  final FlutterSecureStorage _storage;

  Future<List<QueuedCheckIn>> pending() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => QueuedCheckIn.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      // Corrupt queue: drop it rather than block every future check-in.
      await _storage.delete(key: _key);
      return const [];
    }
  }

  Future<void> enqueue(QueuedCheckIn item) async {
    final items = [...await pending(), item];
    await _write(items);
  }

  Future<void> remove(String clientNonce) async {
    final items = (await pending()).where((i) => i.clientNonce != clientNonce);
    await _write(items.toList());
  }

  Future<void> replace(QueuedCheckIn item) async {
    final items = (await pending())
        .map((i) => i.clientNonce == item.clientNonce ? item : i)
        .toList();
    await _write(items);
  }

  Future<void> clear() => _storage.delete(key: _key);

  Future<void> _write(List<QueuedCheckIn> items) => _storage.write(
        key: _key,
        value: jsonEncode(items.map((i) => i.toJson()).toList()),
      );
}
