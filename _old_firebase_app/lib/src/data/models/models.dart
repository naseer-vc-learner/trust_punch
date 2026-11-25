import 'package:cloud_firestore/cloud_firestore.dart';

import 'flag_reason.dart';

export 'flag_reason.dart';

/// A registered work location. Read-only on the client.
class Site {
  const Site({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final double radiusMeters;

  factory Site.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    return Site(
      id: doc.id,
      name: data['name'] as String? ?? 'Unnamed site',
      latitude: (data['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (data['longitude'] as num?)?.toDouble() ?? 0,
      radiusMeters: (data['radiusMeters'] as num?)?.toDouble() ?? 1000,
    );
  }
}

class Employee {
  const Employee({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.registeredDeviceId,
    required this.hasFaceEnrollment,
    required this.assignedSiteIds,
    required this.status,
  });

  final String id;
  final String name;
  final String email;
  final String role;
  final String? registeredDeviceId;
  final bool hasFaceEnrollment;
  final List<String> assignedSiteIds;
  final String status;

  bool get isAdmin => role == 'admin';
  bool get isEnrolled => hasFaceEnrollment && registeredDeviceId != null;

  factory Employee.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    return Employee(
      id: doc.id,
      name: data['name'] as String? ?? '',
      email: data['email'] as String? ?? '',
      role: data['role'] as String? ?? 'employee',
      registeredDeviceId: data['registeredDeviceId'] as String?,
      // Only the existence of a template is exposed, never the template itself.
      hasFaceEnrollment: data['faceEmbeddingRef'] != null,
      assignedSiteIds:
          (data['assignedSiteIds'] as List<dynamic>? ?? const []).cast<String>(),
      status: data['status'] as String? ?? 'pending_enrollment',
    );
  }
}

/// The employee's working day, as maintained server-side.
///
/// Read-only here: these are the numbers someone gets paid from, and the
/// security rules deny client writes entirely.
class WorkSession {
  const WorkSession({
    required this.id,
    required this.employeeId,
    required this.checkInAt,
    required this.checkOutAt,
    required this.status,
    required this.totalBreakMinutes,
    required this.workedMinutes,
    required this.breakRunningSince,
  });

  final String id;
  final String employeeId;
  final DateTime checkInAt;
  final DateTime? checkOutAt;
  final SessionStatus status;
  final int totalBreakMinutes;
  final int? workedMinutes;

  /// When the current break began, if one is running.
  final DateTime? breakRunningSince;

  /// Live worked time, excluding breaks. Display only — the server recomputes
  /// it authoritatively at checkout.
  Duration get elapsedWorked {
    final end = checkOutAt ?? DateTime.now();
    final gross = end.difference(checkInAt);
    var breakMs = totalBreakMinutes * 60 * 1000;
    if (breakRunningSince != null) {
      breakMs += DateTime.now().difference(breakRunningSince!).inMilliseconds;
    }
    final net = gross.inMilliseconds - breakMs;
    return Duration(milliseconds: net < 0 ? 0 : net);
  }

  factory WorkSession.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    final breaks = (data['breaks'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    final running = breaks.where((b) => b['endAtMs'] == null).toList();

    return WorkSession(
      id: doc.id,
      employeeId: data['employeeId'] as String? ?? '',
      checkInAt: DateTime.fromMillisecondsSinceEpoch(
        (data['checkInAtMs'] as num?)?.toInt() ?? 0,
      ),
      checkOutAt: data['checkOutAtMs'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (data['checkOutAtMs'] as num).toInt(),
            ),
      status: SessionStatus.fromCode(data['status'] as String?),
      totalBreakMinutes: (data['totalBreakMinutes'] as num?)?.toInt() ?? 0,
      workedMinutes: (data['workedMinutes'] as num?)?.toInt(),
      breakRunningSince: running.isEmpty
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (running.first['startAtMs'] as num).toInt(),
            ),
    );
  }
}

/// A stored attendance record, as read back from Firestore.
class AttendanceRecord {
  const AttendanceRecord({
    required this.id,
    required this.employeeId,
    required this.type,
    required this.direction,
    required this.timestamp,
    required this.status,
    required this.flagReason,
    required this.workedMinutes,
    required this.faceMatchScore,
    required this.distanceFromSite,
    required this.deviceTrusted,
    required this.isMockLocationFlag,
  });

  final String id;
  final String employeeId;
  final AttendanceType type;
  final AttendanceDirection direction;
  final DateTime timestamp;
  final AttendanceStatus status;
  final FlagReason? flagReason;
  final int? workedMinutes;
  final double faceMatchScore;
  final double? distanceFromSite;
  final bool deviceTrusted;
  final bool isMockLocationFlag;

  factory AttendanceRecord.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    final reason = data['flagReason'] as String?;
    return AttendanceRecord(
      id: doc.id,
      employeeId: data['employeeId'] as String? ?? '',
      type: AttendanceType.fromCode(data['type'] as String?),
      direction: AttendanceDirection.fromCode(data['direction'] as String?),
      workedMinutes: (data['workedMinutes'] as num?)?.toInt(),
      timestamp:
          (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0),
      status: AttendanceStatus.fromCode(data['status'] as String?),
      flagReason: reason == null ? null : FlagReason.fromCode(reason),
      faceMatchScore: (data['faceMatchScore'] as num?)?.toDouble() ?? 0,
      distanceFromSite: (data['distanceFromSite'] as num?)?.toDouble(),
      deviceTrusted: data['deviceTrusted'] as bool? ?? false,
      isMockLocationFlag: data['isMockLocationFlag'] as bool? ?? false,
    );
  }
}

/// The server's verdict on one submission. This is the only thing the client
/// is allowed to treat as the outcome of a check-in.
class CheckInOutcome {
  const CheckInOutcome({
    required this.recordId,
    required this.direction,
    required this.sessionStatus,
    required this.workedMinutes,
    required this.breakMinutes,
    required this.status,
    required this.flagReason,
    required this.message,
    required this.distanceFromSiteMeters,
    required this.serverTimestamp,
  });

  final String recordId;
  final AttendanceDirection direction;

  /// State of the working day after this punch — tells the home screen which
  /// action to offer next without waiting for a Firestore round trip.
  final SessionStatus sessionStatus;
  final int? workedMinutes;
  final int? breakMinutes;
  final AttendanceStatus status;
  final FlagReason? flagReason;
  final String message;
  final double? distanceFromSiteMeters;
  final DateTime serverTimestamp;

  bool get isApproved => status == AttendanceStatus.approved;

  factory CheckInOutcome.fromMap(Map<String, dynamic> map) {
    final reason = map['flagReason'] as String?;
    return CheckInOutcome(
      recordId: map['recordId'] as String? ?? '',
      direction: AttendanceDirection.fromCode(map['direction'] as String?),
      sessionStatus: SessionStatus.fromCode(map['sessionStatus'] as String?),
      workedMinutes: (map['workedMinutes'] as num?)?.toInt(),
      breakMinutes: (map['breakMinutes'] as num?)?.toInt(),
      status: AttendanceStatus.fromCode(map['status'] as String?),
      flagReason: reason == null ? null : FlagReason.fromCode(reason),
      message: map['message'] as String? ?? 'Submitted.',
      distanceFromSiteMeters: (map['distanceFromSiteMeters'] as num?)?.toDouble(),
      serverTimestamp:
          DateTime.tryParse(map['serverTimestampIso'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

/// A server-issued liveness prompt. Short-lived and single-use.
class LivenessChallenge {
  const LivenessChallenge({
    required this.challengeId,
    required this.prompts,
    required this.expiresAt,
  });

  final String challengeId;
  final List<String> prompts;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  factory LivenessChallenge.fromMap(Map<String, dynamic> map) => LivenessChallenge(
        challengeId: map['challengeId'] as String,
        prompts: (map['prompts'] as List<dynamic>).cast<String>(),
        expiresAt:
            DateTime.fromMillisecondsSinceEpoch((map['expiresAtMs'] as num).toInt()),
      );

  static const promptCopy = <String, String>{
    'blink_twice': 'Blink twice',
    'turn_head_left': 'Slowly turn your head to the left',
    'turn_head_right': 'Slowly turn your head to the right',
    'look_straight_then_left': 'Look straight ahead, then turn left',
  };

  String get instruction =>
      prompts.map((p) => promptCopy[p] ?? p).join(', then ');
}

/// What the on-device detector actually measured during the challenge.
///
/// Sent raw so the server can re-derive whether the claimed action happened —
/// the client's own opinion is never the deciding input.
class LivenessEvidence {
  const LivenessEvidence({
    required this.completedActions,
    required this.framesAnalysed,
    required this.maxLeftEyeOpenProb,
    required this.minLeftEyeOpenProb,
    required this.maxHeadEulerAngleY,
    required this.minHeadEulerAngleY,
    required this.faceDetected,
  });

  final List<String> completedActions;
  final int framesAnalysed;
  final double maxLeftEyeOpenProb;
  final double minLeftEyeOpenProb;
  final double maxHeadEulerAngleY;
  final double minHeadEulerAngleY;
  final bool faceDetected;

  static const empty = LivenessEvidence(
    completedActions: [],
    framesAnalysed: 0,
    maxLeftEyeOpenProb: 0,
    minLeftEyeOpenProb: 1,
    maxHeadEulerAngleY: 0,
    minHeadEulerAngleY: 0,
    faceDetected: false,
  );

  Map<String, dynamic> toMap() => {
        'completedActions': completedActions,
        'framesAnalysed': framesAnalysed,
        'maxLeftEyeOpenProb': maxLeftEyeOpenProb,
        'minLeftEyeOpenProb': minLeftEyeOpenProb,
        'maxHeadEulerAngleY': maxHeadEulerAngleY,
        'minHeadEulerAngleY': minHeadEulerAngleY,
        'faceDetected': faceDetected,
      };
}
