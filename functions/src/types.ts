/** Shared domain types. Mirrors `lib/src/data/models` on the Flutter side. */

export type AttendanceType = 'onsite' | 'wfh';

/**
 * Which edge of the working day a punch represents.
 *
 * All four carry identical verification weight — a checkout proves presence
 * exactly as a check-in does, so nothing here weakens the face/liveness/geofence
 * chain. Only the state rules differ.
 */
export type AttendanceDirection = 'in' | 'out' | 'break_start' | 'break_end';
export type AttendanceStatus = 'approved' | 'flagged' | 'rejected';

/** Machine-readable reasons. The client maps these to user-facing copy. */
export enum FlagReason {
  FaceMatchBelowThreshold = 'FACE_MATCH_BELOW_THRESHOLD',
  FaceMatchBorderline = 'FACE_MATCH_BORDERLINE',
  NoLiveFaceDetected = 'NO_LIVE_FACE_DETECTED',
  LivenessChallengeFailed = 'LIVENESS_CHALLENGE_FAILED',
  LivenessChallengeExpired = 'LIVENESS_CHALLENGE_EXPIRED',
  OutsideGeofence = 'OUTSIDE_GEOFENCE',
  MockLocationDetected = 'MOCK_LOCATION_DETECTED',
  LowGpsAccuracy = 'LOW_GPS_ACCURACY',
  UnregisteredDevice = 'UNREGISTERED_DEVICE',
  DevicePendingApproval = 'DEVICE_PENDING_APPROVAL',
  DeviceSharedAcrossEmployees = 'DEVICE_SHARED_ACROSS_EMPLOYEES',
  CompromisedDevice = 'COMPROMISED_DEVICE',
  SiteNotAssigned = 'SITE_NOT_ASSIGNED',
  WfhNotAuthorised = 'WFH_NOT_AUTHORISED',
  DuplicateSubmission = 'DUPLICATE_SUBMISSION',
  ImpossibleTravel = 'IMPOSSIBLE_TRAVEL',
  ReplayedFaceScore = 'REPLAYED_FACE_SCORE',
  EmployeeInactive = 'EMPLOYEE_INACTIVE',

  // --- working-day state -------------------------------------------------
  AlreadyCheckedIn = 'ALREADY_CHECKED_IN',
  NoOpenCheckIn = 'NO_OPEN_CHECK_IN',
  AlreadyOnBreak = 'ALREADY_ON_BREAK',
  NotOnBreak = 'NOT_ON_BREAK',
  /** Checked out long after the shift should have ended — usually a forgotten
   *  checkout. The real timestamp is kept; the record is flagged for review. */
  LateCheckout = 'LATE_CHECKOUT',
  /** Break time exceeded the daily allowance. */
  BreakOverrun = 'BREAK_OVERRUN',
  /** Shift ran well past the standard working day. */
  OvertimeRecorded = 'OVERTIME_RECORDED',
}

/** One break within a working day. `endAtMs` is null while it is running. */
export interface BreakPeriod {
  startAtMs: number;
  endAtMs: number | null;
  startRecordId: string;
  endRecordId?: string;
}

/**
 * The open working day for one employee.
 *
 * Keyed by employee + the day they checked IN, so an overnight shift stays one
 * session rather than splitting at midnight.
 */
export interface WorkSession {
  employeeId: string;
  dayKey: string;
  checkInAtMs: number;
  checkInRecordId: string;
  checkOutAtMs: number | null;
  checkOutRecordId: string | null;
  breaks: BreakPeriod[];
  status: 'open' | 'on_break' | 'closed';
  totalBreakMinutes: number;
  workedMinutes: number | null;
  flags: FlagReason[];
}

export interface Employee {
  name: string;
  email: string;
  role: 'employee' | 'manager' | 'admin';
  registeredDeviceId: string | null;
  faceEmbeddingRef: string | null;
  assignedSiteIds: string[];
  status: 'active' | 'suspended' | 'pending_enrollment';
  fcmTokens?: string[];
}

export interface Site {
  name: string;
  latitude: number;
  longitude: number;
  radiusMeters: number;
}

export interface DeviceRecord {
  employeeId: string;
  registeredAt: FirebaseFirestore.Timestamp;
  approved: boolean;
  platform: string;
  model: string;
  /** Set when an admin approves/rejects; audit trail for the trust decision. */
  approvedBy?: string;
  approvedAt?: FirebaseFirestore.Timestamp;
}

export interface GeoPoint {
  latitude: number;
  longitude: number;
}

/** Exactly what the client is allowed to send. Nothing here is trusted. */
export interface CheckInRequest {
  type: AttendanceType;
  /** Defaults to 'in' when absent, so older clients keep working. */
  direction?: AttendanceDirection;
  siteId?: string;
  selfieBase64: string;
  latitude?: number;
  longitude?: number;
  accuracyMeters?: number;
  /** Android `Location.isFromMockProvider`. Absent on iOS. */
  isFromMockProvider?: boolean;
  deviceId: string;
  /** Signals from the on-device root/jailbreak check. */
  deviceCompromised?: boolean;
  /** Id of the server-issued liveness challenge this capture answers. */
  challengeId: string;
  /** What the on-device ML Kit detector actually observed. */
  livenessEvidence: LivenessEvidence;
  /** Client-side idempotency key so a retry cannot double-punch. */
  clientNonce: string;
}

export interface LivenessEvidence {
  /** e.g. ['blink_twice'] — must equal the challenge's prompts. */
  completedActions: string[];
  /** ML Kit frame stats; used to reject a still photo held to the camera. */
  framesAnalysed: number;
  maxLeftEyeOpenProb: number;
  minLeftEyeOpenProb: number;
  maxHeadEulerAngleY: number;
  minHeadEulerAngleY: number;
  faceDetected: boolean;
}

export interface CheckInResponse {
  recordId: string;
  direction: AttendanceDirection;
  /** State after this punch, so the client can render the right next action. */
  sessionStatus: 'open' | 'on_break' | 'closed' | 'none';
  workedMinutes: number | null;
  breakMinutes: number | null;
  status: AttendanceStatus;
  flagReason: FlagReason | null;
  /** Human-readable, server-authored. Client never invents these. */
  message: string;
  distanceFromSiteMeters: number | null;
  serverTimestampIso: string;
}

export interface AttendanceRecord {
  employeeId: string;
  type: AttendanceType;
  direction: AttendanceDirection;
  /** The working day this punch belongs to. */
  sessionId: string | null;
  /** Set on a checkout: minutes worked, excluding breaks. */
  workedMinutes: number | null;
  /** Set on a checkout or break_end: accumulated break minutes that day. */
  breakMinutes: number | null;
  timestamp: FirebaseFirestore.Timestamp;
  faceMatchScore: number;
  gpsCoordinates: FirebaseFirestore.GeoPoint | null;
  gpsAccuracyMeters: number | null;
  siteId: string | null;
  distanceFromSite: number | null;
  isMockLocationFlag: boolean;
  deviceId: string;
  deviceTrusted: boolean;
  selfieStorageRef: string | null;
  status: AttendanceStatus;
  flagReason: FlagReason | null;
  /** Every reason that fired, not just the decisive one — for the audit trail. */
  allFlagReasons: FlagReason[];
  clientNonce: string;
  anomalyReviewed: boolean;
}

export interface LivenessChallenge {
  employeeId: string;
  prompts: string[];
  issuedAtMs: number;
  expiresAtMs: number;
  consumed: boolean;
}
