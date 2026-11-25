// The constructor assigns private fields from public named parameters, so
// callers never see an underscore in the API. Initializing formals cannot do
// that without leaking `_api:` into the call site.
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import '../services/device_service.dart';
import '../services/location_service.dart';
import '../services/offline_queue.dart';
import '../services/trustpunch_api.dart';

/// The submission pipeline: gather signals, hand them to the server, surface
/// the server's verdict — and never anything else.
///
/// Offline behaviour: a capture that cannot reach the server is stored as
/// `pendingSync`, which is a distinct state from `approved` everywhere in the
/// UI. The app has no code path that promotes a queued item to approved on its
/// own; only a server response can do that.
class AttendanceRepository {
  AttendanceRepository({
    required TrustPunchApi api,
    required DeviceService devices,
    required LocationService location,
    required OfflineQueue queue,
    FirebaseFirestore? firestore,
    ConnectivityCheck? isOnline,
  })  : _api = api,
        _devices = devices,
        _location = location,
        _queue = queue,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _isOnline = isOnline ?? _defaultConnectivityCheck;

  final TrustPunchApi _api;
  final DeviceService _devices;
  final LocationService _location;
  final OfflineQueue _queue;
  final FirebaseFirestore _firestore;
  final ConnectivityCheck _isOnline;

  Future<LivenessChallenge> requestChallenge() => _api.issueLivenessChallenge();

  /// Submits a completed capture.
  ///
  /// Returns null when the attempt was queued instead of judged — the caller
  /// must render that as "waiting to be confirmed", never as a success.
  Future<CheckInOutcome?> submit({
    required AttendanceType type,
    required AttendanceDirection direction,
    required Uint8List selfie,
    required String challengeId,
    required LivenessEvidence liveness,
    String? siteId,
  }) async {
    final identity = await _devices.identity();
    final integrity = await _devices.integrity();

    // Refuse locally as well as server-side. The server is the authority, but
    // there is no reason to ship a selfie off a device we already distrust.
    if (integrity.isCompromised) {
      throw const CompromisedDeviceException();
    }

    LocationFix? fix;
    if (type == AttendanceType.onsite) {
      fix = await _location.currentFix();
    }

    final queued = QueuedCheckIn(
      clientNonce: const Uuid().v4(),
      type: type,
      direction: direction,
      capturedAt: DateTime.now(),
      selfieBase64: base64Encode(selfie),
      deviceId: identity.deviceId,
      challengeId: challengeId,
      liveness: liveness,
      siteId: siteId,
      latitude: fix?.latitude,
      longitude: fix?.longitude,
      accuracyMeters: fix?.accuracyMeters,
      isFromMockProvider: fix?.isFromMockProvider ?? false,
      deviceCompromised: integrity.isCompromised,
    );

    if (!await _isOnline()) {
      await _queue.enqueue(queued);
      return null;
    }

    try {
      return await _send(queued);
    } on ApiException catch (e) {
      if (e.isTransient) {
        await _queue.enqueue(queued);
        return null;
      }
      rethrow;
    }
  }

  /// Drains the offline queue. Called on app resume and when connectivity
  /// returns.
  ///
  /// Stale items are dropped rather than sent: their liveness challenge has
  /// expired, so submitting them would only produce a confusing rejection.
  Future<List<CheckInOutcome>> flushQueue() async {
    final outcomes = <CheckInOutcome>[];
    if (!await _isOnline()) return outcomes;

    for (final item in await _queue.pending()) {
      if (item.isStale || item.attempts >= OfflineQueue.maxAttempts) {
        await _queue.remove(item.clientNonce);
        continue;
      }
      try {
        outcomes.add(await _send(item));
        await _queue.remove(item.clientNonce);
      } on ApiException catch (e) {
        if (e.isTransient) {
          await _queue.replace(item.withAttempt());
        } else {
          await _queue.remove(item.clientNonce);
        }
      }
    }
    return outcomes;
  }

  Future<List<QueuedCheckIn>> pendingSubmissions() => _queue.pending();

  Future<CheckInOutcome> _send(QueuedCheckIn item) => _api.submitCheckIn(
        type: item.type,
        direction: item.direction,
        selfie: item.selfieBytes,
        deviceId: item.deviceId,
        challengeId: item.challengeId,
        clientNonce: item.clientNonce,
        liveness: item.liveness,
        siteId: item.siteId,
        latitude: item.latitude,
        longitude: item.longitude,
        accuracyMeters: item.accuracyMeters,
        isFromMockProvider: item.isFromMockProvider,
        deviceCompromised: item.deviceCompromised,
      );

  // ---- reads (allowed by the security rules for your own records) --------

  Stream<List<AttendanceRecord>> myRecords(String employeeId, {int limit = 30}) =>
      _firestore
          .collection('attendance')
          .where('employeeId', isEqualTo: employeeId)
          .orderBy('timestamp', descending: true)
          .limit(limit)
          .snapshots()
          .map((s) => s.docs.map(AttendanceRecord.fromDoc).toList());

  /// The employee's open working day, or null when not checked in.
  ///
  /// Followed through the `openSessionId` pointer on the employee document so
  /// an overnight shift stays one session rather than splitting at midnight.
  Stream<WorkSession?> openSession(String employeeId) => _firestore
      .collection('employees')
      .doc(employeeId)
      .snapshots()
      .asyncMap((doc) async {
        final sessionId = doc.data()?['openSessionId'] as String?;
        if (sessionId == null) return null;
        final snap =
            await _firestore.collection('work_sessions').doc(sessionId).get();
        return snap.exists ? WorkSession.fromDoc(snap) : null;
      });

  Stream<Employee?> employee(String employeeId) => _firestore
      .collection('employees')
      .doc(employeeId)
      .snapshots()
      .map((doc) => doc.exists ? Employee.fromDoc(doc) : null);

  Future<List<Site>> sites(List<String> siteIds) async {
    if (siteIds.isEmpty) return const [];
    final snaps = await Future.wait(
      siteIds.map((id) => _firestore.collection('sites').doc(id).get()),
    );
    return snaps.where((s) => s.exists).map(Site.fromDoc).toList();
  }
}

/// Injectable connectivity probe. `Connectivity` itself has a factory
/// constructor and cannot be subclassed, so the seam lives here instead.
typedef ConnectivityCheck = Future<bool> Function();

Future<bool> _defaultConnectivityCheck() async {
  final result = await Connectivity().checkConnectivity();
  return !result.contains(ConnectivityResult.none);
}

class CompromisedDeviceException implements Exception {
  const CompromisedDeviceException();
  @override
  String toString() =>
      'This device appears to be rooted, jailbroken or emulated. '
      'Attendance is blocked. Contact IT.';
}

