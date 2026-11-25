/// Kinds of leave a worker can ask for. Kept short on purpose: the demo has
/// no leave balances or policies, only a record of who is away and why.
enum LeaveType { annual, sick, unpaid }

/// Pending until a supervisor decides; only approved leave counts as away.
enum LeaveStatus { pending, approved, rejected }

class LeaveRequest {
  const LeaveRequest({
    required this.id,
    required this.workerId,
    required this.workerName,
    required this.type,
    required this.from,
    required this.to,
    required this.reason,
    required this.status,
    required this.requestedAt,
    this.decidedAt,
  });

  final String id;
  final String workerId;

  /// Copied at request time so the record still reads correctly after the
  /// worker is removed from the phone.
  final String workerName;
  final LeaveType type;

  /// First and last day of leave, both included, as local dates (midnight).
  final DateTime from;
  final DateTime to;
  final String reason;
  final LeaveStatus status;
  final DateTime requestedAt;
  final DateTime? decidedAt;

  /// Calendar days covered, weekends included.
  int get days =>
      _utcDate(to).difference(_utcDate(from)).inDays + 1;

  /// Whether [day] falls inside this leave, whatever its status.
  bool covers(DateTime day) {
    final d = dateOnly(day);
    return !d.isBefore(from) && !d.isAfter(to);
  }

  /// Whether the two ranges share at least one day.
  bool overlaps(DateTime otherFrom, DateTime otherTo) =>
      !dateOnly(otherTo).isBefore(from) && !dateOnly(otherFrom).isAfter(to);

  LeaveRequest decided(LeaveStatus newStatus, DateTime at) => LeaveRequest(
        id: id,
        workerId: workerId,
        workerName: workerName,
        type: type,
        from: from,
        to: to,
        reason: reason,
        status: newStatus,
        requestedAt: requestedAt,
        decidedAt: at,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'workerId': workerId,
        'workerName': workerName,
        'type': type.name,
        'from': _dateString(from),
        'to': _dateString(to),
        'reason': reason,
        'status': status.name,
        'requestedAt': requestedAt.toIso8601String(),
        if (decidedAt != null) 'decidedAt': decidedAt!.toIso8601String(),
      };

  factory LeaveRequest.fromJson(Map<String, dynamic> json) => LeaveRequest(
        id: json['id'] as String,
        workerId: json['workerId'] as String,
        workerName: json['workerName'] as String? ?? '',
        type: LeaveType.values.byName(json['type'] as String),
        from: DateTime.parse(json['from'] as String),
        to: DateTime.parse(json['to'] as String),
        reason: json['reason'] as String? ?? '',
        status: LeaveStatus.values.byName(json['status'] as String),
        requestedAt: DateTime.parse(json['requestedAt'] as String),
        decidedAt: json['decidedAt'] == null
            ? null
            : DateTime.parse(json['decidedAt'] as String),
      );
}

/// Midnight of [d]'s local date.
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Day arithmetic in UTC, so a daylight-saving change cannot make a day
/// 23 or 25 hours long and throw the count off by one.
DateTime _utcDate(DateTime d) => DateTime.utc(d.year, d.month, d.day);

String _dateString(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
