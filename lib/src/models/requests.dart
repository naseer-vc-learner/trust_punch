import 'attendance.dart';
import 'leave.dart' show dateOnly;

/// Pending until a supervisor decides; a decision is never changed after.
enum RequestStatus { pending, approved, rejected }

/// A supervisor's decision on one worker's overtime for one day.
///
/// Overtime is worked time beyond the 8-hour day. It is not paid until
/// approved; [minutes] records how much was approved, so hours changed later
/// (by a correction) cannot raise it silently.
class OvertimeDecision {
  const OvertimeDecision({
    required this.workerId,
    required this.date,
    required this.approved,
    required this.minutes,
    required this.decidedAt,
  });

  final String workerId;

  /// The day, as a local date (midnight).
  final DateTime date;
  final bool approved;
  final int minutes;
  final DateTime decidedAt;

  Map<String, dynamic> toJson() => {
        'workerId': workerId,
        'date': date.toIso8601String(),
        'approved': approved,
        'minutes': minutes,
        'decidedAt': decidedAt.toIso8601String(),
      };

  factory OvertimeDecision.fromJson(Map<String, dynamic> json) =>
      OvertimeDecision(
        workerId: json['workerId'] as String,
        date: dateOnly(DateTime.parse(json['date'] as String)),
        approved: json['approved'] as bool,
        minutes: (json['minutes'] as num).toInt(),
        decidedAt: DateTime.parse(json['decidedAt'] as String),
      );
}

/// A worker's request to fix a missed check-in or check-out.
///
/// Approving it changes the day's punches (see
/// `AttendanceStore.decideCorrection`); the request itself, with its reason
/// and what it replaced, stays on record either way.
class CorrectionRequest {
  const CorrectionRequest({
    required this.id,
    required this.workerId,
    required this.workerName,
    required this.siteId,
    required this.siteName,
    required this.type,
    required this.at,
    required this.reason,
    required this.status,
    required this.requestedAt,
    this.decidedAt,
    this.replacedAt,
    this.replacedAuto = false,
  });

  final String id;
  final String workerId;
  final String workerName;
  final String siteId;
  final String siteName;

  /// [PunchType.checkIn] or [PunchType.checkOut] only.
  final PunchType type;

  /// When the worker says it really happened.
  final DateTime at;
  final String reason;
  final RequestStatus status;
  final DateTime requestedAt;
  final DateTime? decidedAt;

  /// The time of the punch an approval replaced, if it replaced one, and
  /// whether that was an automatic punch.
  final DateTime? replacedAt;
  final bool replacedAuto;

  CorrectionRequest decided(
    RequestStatus newStatus,
    DateTime when, {
    DateTime? replacedAt,
    bool replacedAuto = false,
  }) =>
      CorrectionRequest(
        id: id,
        workerId: workerId,
        workerName: workerName,
        siteId: siteId,
        siteName: siteName,
        type: type,
        at: at,
        reason: reason,
        status: newStatus,
        requestedAt: requestedAt,
        decidedAt: when,
        replacedAt: replacedAt,
        replacedAuto: replacedAuto,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'workerId': workerId,
        'workerName': workerName,
        'siteId': siteId,
        'siteName': siteName,
        'type': type.name,
        'at': at.toIso8601String(),
        'reason': reason,
        'status': status.name,
        'requestedAt': requestedAt.toIso8601String(),
        if (decidedAt != null) 'decidedAt': decidedAt!.toIso8601String(),
        if (replacedAt != null) 'replacedAt': replacedAt!.toIso8601String(),
        if (replacedAuto) 'replacedAuto': true,
      };

  factory CorrectionRequest.fromJson(Map<String, dynamic> json) =>
      CorrectionRequest(
        id: json['id'] as String,
        workerId: json['workerId'] as String,
        workerName: json['workerName'] as String? ?? '',
        siteId: json['siteId'] as String,
        siteName: json['siteName'] as String? ?? '',
        type: PunchType.values.byName(json['type'] as String),
        at: DateTime.parse(json['at'] as String),
        reason: json['reason'] as String? ?? '',
        status: RequestStatus.values.byName(json['status'] as String),
        requestedAt: DateTime.parse(json['requestedAt'] as String),
        decidedAt: json['decidedAt'] == null
            ? null
            : DateTime.parse(json['decidedAt'] as String),
        replacedAt: json['replacedAt'] == null
            ? null
            : DateTime.parse(json['replacedAt'] as String),
        replacedAuto: json['replacedAuto'] as bool? ?? false,
      );
}
