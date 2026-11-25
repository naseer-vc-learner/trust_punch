/// Mirrors `functions/src/types.ts::FlagReason`.
///
/// The server sends the machine-readable code and its own message. The client
/// keeps this enum so it can branch on outcome (retry vs. contact manager)
/// without string-matching prose, but it never invents a verdict.
enum FlagReason {
  faceMatchBelowThreshold('FACE_MATCH_BELOW_THRESHOLD'),
  faceMatchBorderline('FACE_MATCH_BORDERLINE'),
  noLiveFaceDetected('NO_LIVE_FACE_DETECTED'),
  livenessChallengeFailed('LIVENESS_CHALLENGE_FAILED'),
  livenessChallengeExpired('LIVENESS_CHALLENGE_EXPIRED'),
  outsideGeofence('OUTSIDE_GEOFENCE'),
  mockLocationDetected('MOCK_LOCATION_DETECTED'),
  lowGpsAccuracy('LOW_GPS_ACCURACY'),
  unregisteredDevice('UNREGISTERED_DEVICE'),
  devicePendingApproval('DEVICE_PENDING_APPROVAL'),
  deviceSharedAcrossEmployees('DEVICE_SHARED_ACROSS_EMPLOYEES'),
  compromisedDevice('COMPROMISED_DEVICE'),
  siteNotAssigned('SITE_NOT_ASSIGNED'),
  wfhNotAuthorised('WFH_NOT_AUTHORISED'),
  duplicateSubmission('DUPLICATE_SUBMISSION'),
  impossibleTravel('IMPOSSIBLE_TRAVEL'),
  replayedFaceScore('REPLAYED_FACE_SCORE'),
  employeeInactive('EMPLOYEE_INACTIVE'),
  alreadyCheckedIn('ALREADY_CHECKED_IN'),
  noOpenCheckIn('NO_OPEN_CHECK_IN'),
  alreadyOnBreak('ALREADY_ON_BREAK'),
  notOnBreak('NOT_ON_BREAK'),
  lateCheckout('LATE_CHECKOUT'),
  breakOverrun('BREAK_OVERRUN'),
  overtimeRecorded('OVERTIME_RECORDED'),
  unknown('UNKNOWN');

  const FlagReason(this.code);

  final String code;

  static FlagReason fromCode(String? code) {
    if (code == null) return FlagReason.unknown;
    return FlagReason.values.firstWhere(
      (r) => r.code == code,
      orElse: () => FlagReason.unknown,
    );
  }

  /// Whether retrying the capture could plausibly succeed. Drives whether the
  /// result screen offers "Try again" or "Contact your manager".
  bool get isRetryable => switch (this) {
        FlagReason.faceMatchBelowThreshold ||
        FlagReason.noLiveFaceDetected ||
        FlagReason.livenessChallengeFailed ||
        FlagReason.livenessChallengeExpired ||
        FlagReason.outsideGeofence ||
        FlagReason.lowGpsAccuracy ||
        // The employee simply pressed the wrong button; the fix is to press
        // the right one, which the home screen now prevents anyway.
        FlagReason.alreadyCheckedIn ||
        FlagReason.noOpenCheckIn ||
        FlagReason.alreadyOnBreak ||
        FlagReason.notOnBreak =>
          true,
        _ => false,
      };

  /// What the employee should do next, when it is not simply "try again".
  String get nextStep => switch (this) {
        FlagReason.compromisedDevice =>
          'Contact IT. Attendance is blocked on rooted or jailbroken devices.',
        FlagReason.devicePendingApproval ||
        FlagReason.unregisteredDevice =>
          'Ask your administrator to approve this device.',
        FlagReason.deviceSharedAcrossEmployees =>
          'This device belongs to another employee. Contact your administrator.',
        FlagReason.wfhNotAuthorised =>
          'Ask your manager to approve a work-from-home day.',
        FlagReason.siteNotAssigned =>
          'Ask your manager to assign you to this site.',
        FlagReason.employeeInactive => 'Contact HR to reactivate your account.',
        FlagReason.alreadyCheckedIn =>
          'You are already checked in — check out instead.',
        FlagReason.noOpenCheckIn => 'Check in first.',
        FlagReason.alreadyOnBreak => 'End your current break first.',
        FlagReason.notOnBreak => 'You are not on a break.',
        FlagReason.lateCheckout =>
          'Your real checkout time was recorded. Your manager will review it.',
        FlagReason.breakOverrun =>
          'Your breaks went over the daily allowance. Your manager will review it.',
        FlagReason.overtimeRecorded => 'No action needed — overtime was recorded.',
        FlagReason.mockLocationDetected =>
          'Turn off mock locations in developer options, then try again.',
        _ => 'Contact your manager if this keeps happening.',
      };
}

enum AttendanceStatus {
  approved,
  flagged,
  rejected,
  pendingSync;

  static AttendanceStatus fromCode(String? code) => switch (code) {
        'approved' => AttendanceStatus.approved,
        'flagged' => AttendanceStatus.flagged,
        'rejected' => AttendanceStatus.rejected,
        _ => AttendanceStatus.pendingSync,
      };

  String get label => switch (this) {
        AttendanceStatus.approved => 'Approved',
        AttendanceStatus.flagged => 'Flagged for review',
        AttendanceStatus.rejected => 'Not accepted',
        AttendanceStatus.pendingSync => 'Waiting to be confirmed',
      };
}

/// Which edge of the working day a punch represents.
///
/// Mirrors `functions/src/types.ts::AttendanceDirection`. Every direction goes
/// through the identical face, liveness and geofence verification — leaving is
/// proved exactly as arriving is.
enum AttendanceDirection {
  checkIn('in'),
  checkOut('out'),
  breakStart('break_start'),
  breakEnd('break_end');

  const AttendanceDirection(this.code);
  final String code;

  static AttendanceDirection fromCode(String? code) => switch (code) {
        'out' => AttendanceDirection.checkOut,
        'break_start' => AttendanceDirection.breakStart,
        'break_end' => AttendanceDirection.breakEnd,
        _ => AttendanceDirection.checkIn,
      };

  String get label => switch (this) {
        AttendanceDirection.checkIn => 'Check in',
        AttendanceDirection.checkOut => 'Check out',
        AttendanceDirection.breakStart => 'Start break',
        AttendanceDirection.breakEnd => 'End break',
      };

  String get pastLabel => switch (this) {
        AttendanceDirection.checkIn => 'Checked in',
        AttendanceDirection.checkOut => 'Checked out',
        AttendanceDirection.breakStart => 'Break started',
        AttendanceDirection.breakEnd => 'Break ended',
      };
}

/// State of the employee's working day.
enum SessionStatus {
  none,
  open,
  onBreak,
  closed;

  static SessionStatus fromCode(String? code) => switch (code) {
        'open' => SessionStatus.open,
        'on_break' => SessionStatus.onBreak,
        'closed' => SessionStatus.closed,
        _ => SessionStatus.none,
      };

  /// What the employee may do next. Drives which buttons the home screen
  /// offers, so an illegal transition cannot be attempted in the first place.
  List<AttendanceDirection> get allowed => switch (this) {
        SessionStatus.open => const [
            AttendanceDirection.breakStart,
            AttendanceDirection.checkOut,
          ],
        SessionStatus.onBreak => const [
            AttendanceDirection.breakEnd,
            AttendanceDirection.checkOut,
          ],
        _ => const [AttendanceDirection.checkIn],
      };
}

enum AttendanceType {
  onsite('onsite'),
  wfh('wfh');

  const AttendanceType(this.code);
  final String code;

  static AttendanceType fromCode(String? code) =>
      code == 'wfh' ? AttendanceType.wfh : AttendanceType.onsite;
}
