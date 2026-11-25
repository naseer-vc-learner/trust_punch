import { config } from './config';
import { FaceMatchResult } from './faceMatch';
import { haversineDistanceMeters } from './lib/geo';
import {
  AttendanceStatus,
  AttendanceType,
  FlagReason,
  GeoPoint,
  LivenessChallenge,
  LivenessEvidence,
  Site,
} from './types';

/**
 * The decision engine.
 *
 * Deliberately pure: no Firestore, no network, no clock. Everything it needs is
 * passed in, so the rules that decide whether attendance counts can be unit
 * tested exhaustively and cannot silently break. `submitCheckIn` is only
 * responsible for fetching inputs and persisting the output.
 */

export interface EvaluationInput {
  type: AttendanceType;
  employeeStatus: 'active' | 'suspended' | 'pending_enrollment';
  /** Sites the employee is allowed to punch in at. */
  assignedSiteIds: string[];
  siteId: string | null;
  site: (Site & { id: string }) | null;

  location: GeoPoint | null;
  accuracyMeters: number | null;
  isFromMockProvider: boolean;

  deviceId: string;
  registeredDeviceId: string | null;
  /** The devices/{deviceId} record, if one exists at all. */
  deviceApproved: boolean | null;
  /** True when devices/{deviceId} is bound to someone else. */
  deviceBoundToOtherEmployee: boolean;
  deviceCompromised: boolean;

  faceMatch: FaceMatchResult;
  liveness: LivenessEvidence;
  challenge: LivenessChallenge | null;
  /** Wall-clock at evaluation time, injected so tests are deterministic. */
  nowMs: number;

  /** True when a wfh_exceptions doc authorises WFH for today. */
  wfhAuthorisedToday: boolean;
}

export interface Decision {
  status: AttendanceStatus;
  /** The most severe reason — what the employee is shown. */
  flagReason: FlagReason | null;
  /** Every rule that fired, in evaluation order. */
  allFlagReasons: FlagReason[];
  distanceFromSiteMeters: number | null;
  deviceTrusted: boolean;
  message: string;
}

/** Reasons that stop the check-in outright rather than recording it flagged. */
const ALWAYS_REJECTING: ReadonlySet<FlagReason> = new Set([
  FlagReason.EmployeeInactive,
  FlagReason.CompromisedDevice,
  FlagReason.NoLiveFaceDetected,
  FlagReason.FaceMatchBelowThreshold,
  FlagReason.LivenessChallengeExpired,
  FlagReason.LivenessChallengeFailed,
  FlagReason.OutsideGeofence,
  FlagReason.MockLocationDetected,
  FlagReason.SiteNotAssigned,
  FlagReason.WfhNotAuthorised,
  // Illegal working-day transitions: recording them would corrupt the hours.
  FlagReason.AlreadyCheckedIn,
  FlagReason.NoOpenCheckIn,
  FlagReason.AlreadyOnBreak,
  FlagReason.NotOnBreak,
]);

/** Whether a reason blocks the punch, given the current policy config. */
function isRejecting(reason: FlagReason): boolean {
  if (reason === FlagReason.UnregisteredDevice) {
    return config.device.rejectUnregisteredDevice;
  }
  return ALWAYS_REJECTING.has(reason);
}

const MESSAGES: Record<FlagReason, string> = {
  [FlagReason.FaceMatchBelowThreshold]:
    'We could not confirm it was you. Try again in good lighting, facing the camera.',
  [FlagReason.FaceMatchBorderline]:
    'Recorded, but the face match was weak. Your manager will review it.',
  [FlagReason.NoLiveFaceDetected]: 'No face was detected in the photo. Please try again.',
  [FlagReason.LivenessChallengeFailed]:
    'The liveness check was not completed. Follow the on-screen prompt exactly.',
  [FlagReason.LivenessChallengeExpired]: 'The check timed out. Please start again.',
  [FlagReason.OutsideGeofence]: 'You are outside your site boundary. Move closer and retry.',
  [FlagReason.MockLocationDetected]:
    'A mock location provider is active. Disable it in developer options and retry.',
  [FlagReason.LowGpsAccuracy]:
    'Recorded, but your GPS signal was weak. Your manager will review it.',
  [FlagReason.UnregisteredDevice]:
    'Recorded from an unrecognised device and flagged for review.',
  [FlagReason.DevicePendingApproval]:
    'This device is awaiting admin approval, so the punch is flagged for review.',
  [FlagReason.DeviceSharedAcrossEmployees]:
    'This device is registered to another employee. Flagged for review.',
  [FlagReason.CompromisedDevice]:
    'This device appears to be rooted or jailbroken. Attendance is blocked. Contact IT.',
  [FlagReason.SiteNotAssigned]: 'You are not assigned to this site.',
  [FlagReason.WfhNotAuthorised]:
    'No approved work-from-home day was found for today. Contact your manager.',
  [FlagReason.DuplicateSubmission]: 'This check-in was already recorded.',
  [FlagReason.ImpossibleTravel]:
    'Recorded, but the location is implausible given your last check-in. Flagged for review.',
  [FlagReason.ReplayedFaceScore]:
    'Recorded, but the verification pattern looks repeated. Flagged for review.',
  [FlagReason.EmployeeInactive]: 'Your account is not active. Contact HR.',
  [FlagReason.AlreadyCheckedIn]:
    'You are already checked in. Check out before checking in again.',
  [FlagReason.NoOpenCheckIn]: 'You are not checked in yet.',
  [FlagReason.AlreadyOnBreak]: 'You are already on a break.',
  [FlagReason.NotOnBreak]: 'You are not on a break.',
  [FlagReason.LateCheckout]:
    'Checked out well after your shift should have ended. The real time was ' +
    'recorded and flagged for your manager.',
  [FlagReason.BreakOverrun]:
    'Your breaks exceeded the daily allowance. Recorded and flagged for review.',
  [FlagReason.OvertimeRecorded]:
    'Recorded — this shift ran past the standard working day.',
};

const APPROVED_MESSAGE = 'Check-in confirmed.';

export function evaluateCheckIn(input: EvaluationInput): Decision {
  const reasons: FlagReason[] = [];
  let distance: number | null = null;

  // --- 1. Account and device posture ------------------------------------
  // Checked first: nothing else matters if the account or hardware is untrusted.
  if (input.employeeStatus !== 'active') {
    reasons.push(FlagReason.EmployeeInactive);
  }

  if (input.deviceCompromised && config.device.blockCompromisedDevices) {
    reasons.push(FlagReason.CompromisedDevice);
  }

  const deviceTrusted =
    input.deviceApproved === true &&
    input.registeredDeviceId === input.deviceId &&
    !input.deviceBoundToOtherEmployee;

  if (input.deviceBoundToOtherEmployee) {
    reasons.push(FlagReason.DeviceSharedAcrossEmployees);
  } else if (input.deviceApproved === null) {
    // Unknown hardware. Flagged (not rejected) by default so a genuine phone
    // upgrade does not lock someone out of attendance entirely; set
    // REJECT_UNREGISTERED_DEVICE=true for a stricter posture.
    reasons.push(FlagReason.UnregisteredDevice);
  } else if (input.deviceApproved === false) {
    reasons.push(FlagReason.DevicePendingApproval);
  } else if (input.registeredDeviceId !== input.deviceId) {
    reasons.push(FlagReason.UnregisteredDevice);
  }

  // --- 2. Liveness ------------------------------------------------------
  // Before face matching: a printed photo can score high, so proving there was
  // a live human in front of the lens is the cheaper, stronger gate.
  reasons.push(...evaluateLiveness(input));

  // --- 3. Face match ----------------------------------------------------
  if (!input.faceMatch.faceFound) {
    reasons.push(FlagReason.NoLiveFaceDetected);
  } else if (input.faceMatch.score < config.face.reviewThreshold) {
    reasons.push(FlagReason.FaceMatchBelowThreshold);
  } else if (input.faceMatch.score < config.face.approveThreshold) {
    reasons.push(FlagReason.FaceMatchBorderline);
  }

  // --- 4. Location ------------------------------------------------------
  if (input.type === 'onsite') {
    const geo = evaluateGeofence(input);
    distance = geo.distanceMeters;
    reasons.push(...geo.reasons);
  } else if (!input.wfhAuthorisedToday) {
    // WFH skips the geofence, which makes "who may claim WFH" a real control.
    reasons.push(FlagReason.WfhNotAuthorised);
  }

  return decide(reasons, distance, deviceTrusted);
}

function evaluateLiveness(input: EvaluationInput): FlagReason[] {
  const { liveness, challenge, nowMs } = input;

  if (!challenge) return [FlagReason.LivenessChallengeFailed];
  if (challenge.consumed) return [FlagReason.LivenessChallengeExpired];
  if (nowMs > challenge.expiresAtMs) return [FlagReason.LivenessChallengeExpired];
  if (!liveness.faceDetected) return [FlagReason.NoLiveFaceDetected];
  if (liveness.framesAnalysed < config.liveness.minFramesAnalysed) {
    return [FlagReason.LivenessChallengeFailed];
  }

  // The client says which prompts it completed; we re-derive from the raw
  // ML Kit measurements whether that claim is physically supported.
  const claimed = new Set(liveness.completedActions);
  for (const prompt of challenge.prompts) {
    if (!claimed.has(prompt)) return [FlagReason.LivenessChallengeFailed];
    if (!evidenceSupports(prompt, liveness)) return [FlagReason.LivenessChallengeFailed];
  }
  return [];
}

/** Does the frame telemetry actually back up the claimed action? */
export function evidenceSupports(prompt: string, e: LivenessEvidence): boolean {
  const blinkDelta = e.maxLeftEyeOpenProb - e.minLeftEyeOpenProb;
  const yawSwing = e.maxHeadEulerAngleY - e.minHeadEulerAngleY;

  switch (prompt) {
    case 'blink_twice':
    case 'blink_once':
      return blinkDelta >= config.liveness.blinkProbabilityDelta;
    case 'turn_head_left':
      return e.minHeadEulerAngleY <= -config.liveness.headTurnDegrees;
    case 'turn_head_right':
      return e.maxHeadEulerAngleY >= config.liveness.headTurnDegrees;
    case 'look_straight_then_left':
      return yawSwing >= config.liveness.headTurnDegrees;
    default:
      // Unknown prompt => cannot be verified => must not pass.
      return false;
  }
}

function evaluateGeofence(input: EvaluationInput): {
  distanceMeters: number | null;
  reasons: FlagReason[];
} {
  const reasons: FlagReason[] = [];

  if (!input.siteId || !input.site) {
    return { distanceMeters: null, reasons: [FlagReason.SiteNotAssigned] };
  }
  if (!input.assignedSiteIds.includes(input.siteId)) {
    return { distanceMeters: null, reasons: [FlagReason.SiteNotAssigned] };
  }
  if (!input.location) {
    return { distanceMeters: null, reasons: [FlagReason.OutsideGeofence] };
  }
  // A spoofed location is a deliberate act, so it outranks the distance result
  // — being "inside" the fence via a mock provider is worse than being outside.
  if (input.isFromMockProvider) {
    reasons.push(FlagReason.MockLocationDetected);
  }

  const distance = haversineDistanceMeters(input.location, {
    latitude: input.site.latitude,
    longitude: input.site.longitude,
  });

  const radius = input.site.radiusMeters || config.geo.defaultRadiusMeters;
  const accuracy = input.accuracyMeters ?? 0;
  const effectiveDistance = config.geo.useAccuracyGrace
    ? Math.max(0, distance - accuracy)
    : distance;

  if (effectiveDistance > radius) {
    reasons.push(FlagReason.OutsideGeofence);
  } else if (accuracy > config.geo.maxAcceptableAccuracyMeters) {
    // Inside the fence, but only because the accuracy circle is huge.
    reasons.push(FlagReason.LowGpsAccuracy);
  }

  return { distanceMeters: distance, reasons };
}

function decide(
  reasons: FlagReason[],
  distance: number | null,
  deviceTrusted: boolean,
): Decision {
  const unique = [...new Set(reasons)];
  const rejecting = unique.find(isRejecting) ?? null;

  if (rejecting) {
    return {
      status: 'rejected',
      flagReason: rejecting,
      allFlagReasons: unique,
      distanceFromSiteMeters: distance,
      deviceTrusted,
      message: MESSAGES[rejecting],
    };
  }
  if (unique.length > 0) {
    return {
      status: 'flagged',
      flagReason: unique[0],
      allFlagReasons: unique,
      distanceFromSiteMeters: distance,
      deviceTrusted,
      message: MESSAGES[unique[0]],
    };
  }
  return {
    status: 'approved',
    flagReason: null,
    allFlagReasons: [],
    distanceFromSiteMeters: distance,
    deviceTrusted,
    message: APPROVED_MESSAGE,
  };
}

export function messageFor(reason: FlagReason | null): string {
  return reason ? MESSAGES[reason] : APPROVED_MESSAGE;
}
