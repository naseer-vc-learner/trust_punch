/**
 * Tunable policy. Every value here is a business decision, not a technical one
 * — these are the defaults I picked; change them before going to production.
 *
 * Override at deploy time with environment variables (functions/.env), so the
 * thresholds can be tightened without a code change.
 */

const num = (key: string, fallback: number): number => {
  const raw = process.env[key];
  if (raw === undefined || raw === '') return fallback;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const bool = (key: string, fallback: boolean): boolean => {
  const raw = process.env[key];
  if (raw === undefined || raw === '') return fallback;
  return raw === 'true' || raw === '1';
};

export const config = {
  face: {
    /** At or above this, the face is accepted outright. */
    approveThreshold: num('FACE_APPROVE_THRESHOLD', 0.85),
    /** Between review and approve: recorded but flagged for a human. */
    reviewThreshold: num('FACE_REVIEW_THRESHOLD', 0.7),
    /** Below reviewThreshold the check-in is rejected, not just flagged. */
    provider: process.env.FACE_MATCH_PROVIDER ?? 'mock',
    /**
     * At or above this, an enrolling face is treated as someone already on the
     * roster. Set higher than `approveThreshold`: wrongly blocking a new hire
     * because they resemble a colleague is worse than the duplicate slipping
     * through to the admin queue.
     */
    duplicateThreshold: num('FACE_DUPLICATE_THRESHOLD', 0.92),
    /** Block a duplicate enrollment outright, or allow it and alert an admin. */
    blockDuplicateEnrollment: bool('BLOCK_DUPLICATE_ENROLLMENT', true),
  },

  geo: {
    /** Fallback when a site document omits radiusMeters. */
    defaultRadiusMeters: num('DEFAULT_SITE_RADIUS_METERS', 1000),
    /**
     * A 500m GPS accuracy circle inside a 1km geofence is meaningless, so we
     * flag anything vaguer than this rather than trusting the centre point.
     */
    maxAcceptableAccuracyMeters: num('MAX_GPS_ACCURACY_METERS', 100),
    /**
     * Grace band: we compare `distance - accuracy` against the radius so an
     * employee standing at the fence line is not punished for GPS jitter.
     */
    useAccuracyGrace: bool('GEOFENCE_ACCURACY_GRACE', true),
    /** km/h. Above this between two check-ins, travel is physically implausible. */
    impossibleTravelKmh: num('IMPOSSIBLE_TRAVEL_KMH', 900),
  },

  liveness: {
    /** How long a server-issued challenge stays valid. */
    challengeTtlSeconds: num('LIVENESS_CHALLENGE_TTL_SECONDS', 90),
    /** Minimum frames the on-device detector must have analysed. */
    minFramesAnalysed: num('LIVENESS_MIN_FRAMES', 12),
    /** A blink means eye-open probability swung across this delta. */
    blinkProbabilityDelta: num('LIVENESS_BLINK_DELTA', 0.5),
    /** Degrees of yaw required to count a head turn. */
    headTurnDegrees: num('LIVENESS_HEAD_TURN_DEGREES', 20),
  },

  device: {
    /** Block outright on rooted/jailbroken devices vs. merely flagging. */
    blockCompromisedDevices: bool('BLOCK_COMPROMISED_DEVICES', true),
    /** Reject a check-in from an unrecognised device instead of flagging it. */
    rejectUnregisteredDevice: bool('REJECT_UNREGISTERED_DEVICE', false),
  },

  work: {
    /** A standard working day, excluding breaks. */
    standardWorkMinutes: num('STANDARD_WORK_MINUTES', 540), // 9 hours
    /** Total break allowance per day. Beyond this the day is flagged. */
    maxBreakMinutes: num('MAX_BREAK_MINUTES', 60), // 1 hour
    /**
     * Slack after the expected end (check-in + work + break) before a checkout
     * counts as "late". Generous on purpose: a genuinely long day should not
     * look the same as a forgotten checkout.
     */
    lateCheckoutGraceMinutes: num('LATE_CHECKOUT_GRACE_MINUTES', 120),
    /** Worked minutes beyond the standard day are noted as overtime. */
    flagOvertime: bool('FLAG_OVERTIME', true),
  },

  wfh: {
    /** Random presence pings per working day. */
    minPingsPerDay: num('WFH_MIN_PINGS', 2),
    maxPingsPerDay: num('WFH_MAX_PINGS', 4),
    /** Minutes an employee has to answer a presence ping. */
    responseWindowMinutes: num('WFH_RESPONSE_WINDOW_MINUTES', 5),
    workDayStartHour: num('WORK_DAY_START_HOUR', 9),
    workDayEndHour: num('WORK_DAY_END_HOUR', 18),
  },

  anomaly: {
    /** How many days back the daily sweep looks. */
    lookbackDays: num('ANOMALY_LOOKBACK_DAYS', 7),
    /** Identical face scores on this many distinct days => replay suspicion. */
    identicalScoreDayThreshold: num('ANOMALY_IDENTICAL_SCORE_DAYS', 3),
    /** Face scores within this epsilon count as "identical". */
    identicalScoreEpsilon: num('ANOMALY_SCORE_EPSILON', 0.0001),
  },

  /** Timezone used for "today", ping scheduling and daily sweeps. */
  timezone: process.env.TP_TIMEZONE ?? 'Asia/Dubai',

  /**
   * Reject callables that arrive without a valid App Check token.
   *
   * Defaults ON in the cloud and OFF under the emulator, where there is no
   * attestation service to issue tokens. `FUNCTIONS_EMULATOR` is set by the
   * emulator itself, so a deployed function can never take the relaxed path.
   */
  requireAppCheck: bool('REQUIRE_APP_CHECK', process.env.FUNCTIONS_EMULATOR !== 'true'),

  storageBucket: process.env.STORAGE_BUCKET ?? undefined,
} as const;

export type Config = typeof config;

/**
 * Deployment region for every function. Keep the client's
 * `FirebaseFunctions.instanceFor(region:)` in sync with this value.
 */
export const REGION = process.env.TP_REGION ?? 'europe-west1';
