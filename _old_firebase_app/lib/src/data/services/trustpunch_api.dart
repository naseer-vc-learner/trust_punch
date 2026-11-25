import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';

import '../models/models.dart';

/// Thin, typed wrapper over the callable Cloud Functions.
///
/// Every method here sends signals and receives a verdict. Nothing in this file
/// computes an outcome, and there is intentionally no method that writes to the
/// `attendance` collection — the security rules would reject it anyway.
class TrustPunchApi {
  TrustPunchApi({FirebaseFunctions? functions, this.region = defaultRegion})
      : _override = functions;

  /// Must match `REGION` in `functions/src/config.ts`.
  static const defaultRegion = 'europe-west1';

  final String region;

  final FirebaseFunctions? _override;

  /// Resolved lazily so a subclass that overrides every call (the test fakes)
  /// never forces Firebase to initialise.
  late final FirebaseFunctions _functions =
      _override ?? FirebaseFunctions.instanceFor(region: region);

  Future<LivenessChallenge> issueLivenessChallenge() async {
    final result = await _call('issueLivenessChallenge', const {});
    return LivenessChallenge.fromMap(result);
  }

  Future<CheckInOutcome> submitCheckIn({
    required AttendanceType type,
    required AttendanceDirection direction,
    required Uint8List selfie,
    required String deviceId,
    required String challengeId,
    required String clientNonce,
    required LivenessEvidence liveness,
    String? siteId,
    double? latitude,
    double? longitude,
    double? accuracyMeters,
    bool isFromMockProvider = false,
    bool deviceCompromised = false,
  }) async {
    final result = await _call('submitCheckIn', {
      'type': type.code,
      'direction': direction.code,
      'selfieBase64': base64Encode(selfie),
      'deviceId': deviceId,
      'challengeId': challengeId,
      'clientNonce': clientNonce,
      'livenessEvidence': liveness.toMap(),
      'siteId': ?siteId,
      'latitude': ?latitude,
      'longitude': ?longitude,
      'accuracyMeters': ?accuracyMeters,
      'isFromMockProvider': isFromMockProvider,
      'deviceCompromised': deviceCompromised,
    });
    return CheckInOutcome.fromMap(result);
  }

  Future<Map<String, dynamic>> registerDevice({
    required String deviceId,
    required String platform,
    required String model,
    required bool compromised,
  }) =>
      _call('registerDevice', {
        'deviceId': deviceId,
        'platform': platform,
        'model': model,
        'compromised': compromised,
      });

  Future<Map<String, dynamic>> enrollFace(List<Uint8List> frames) => _call(
        'enrollFace',
        {'framesBase64': frames.map(base64Encode).toList()},
      );

  Future<void> registerFcmToken(String token) =>
      _call('registerFcmToken', {'token': token});

  Future<Map<String, dynamic>> requestWfhDay({
    required DateTime date,
    required String reason,
  }) =>
      _call('requestWfhDay', {'date': _dateKey(date), 'reason': reason});

  Future<Map<String, dynamic>> approveWfhDay({
    required String employeeId,
    required DateTime date,
    required String reason,
  }) =>
      _call('approveWfhDay', {
        'employeeId': employeeId,
        'date': _dateKey(date),
        'reason': reason,
      });

  Future<Map<String, dynamic>> approveDevice({
    required String deviceId,
    required bool approve,
  }) =>
      _call('approveDevice', {'deviceId': deviceId, 'approve': approve});

  Future<Map<String, dynamic>> reviewAttendanceRecord({
    required String recordId,
    required bool accepted,
    String? note,
  }) =>
      _call('reviewAttendanceRecord', {
        'recordId': recordId,
        'accepted': accepted,
        'note': ?note,
      });

  Future<Map<String, dynamic>> respondToPresencePing({
    required String pingId,
    required String attendanceRecordId,
  }) =>
      _call('respondToPresencePing', {
        'pingId': pingId,
        'attendanceRecordId': attendanceRecordId,
      });

  Future<Map<String, dynamic>> _call(String name, Map<String, dynamic> payload) async {
    try {
      final response = await _functions.httpsCallable(name).call<dynamic>(payload);
      return Map<String, dynamic>.from(response.data as Map);
    } on FirebaseFunctionsException catch (e) {
      throw ApiException(code: e.code, message: e.message ?? 'Request failed.');
    }
  }

  static String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

class ApiException implements Exception {
  ApiException({required this.code, required this.message});

  final String code;
  final String message;

  /// Network-shaped failures are the ones worth queueing for a retry; an
  /// `invalid-argument` will fail identically forever.
  bool get isTransient => const {
        'unavailable',
        'deadline-exceeded',
        'internal',
        'resource-exhausted',
      }.contains(code);

  @override
  String toString() => message;
}
