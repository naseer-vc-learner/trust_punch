import * as admin from 'firebase-admin';
import { GeoPoint, Timestamp } from 'firebase-admin/firestore';
import { HttpsError, onCall } from 'firebase-functions/v2/https';
import * as logger from 'firebase-functions/logger';
import { CHALLENGES_COLLECTION } from './challenges';
import { config, REGION } from './config';
import { getFaceMatcher } from './faceMatch';
import {
  decodeSelfie,
  optionalNumber,
  requireAuth,
  requireBool,
  requireEnum,
  requireString,
} from './lib/guards';
import { dayKey } from './lib/time';
import { Decision, evaluateCheckIn, messageFor } from './verification';
import {
  applyDirection,
  directionMessage,
  DirectionOutcome,
  evaluateDirection,
  SessionView,
} from './session';
import {
  AttendanceDirection,
  AttendanceRecord,
  AttendanceType,
  CheckInResponse,
  Employee,
  FlagReason,
  LivenessChallenge,
  LivenessEvidence,
  Site,
  WorkSession,
} from './types';

/**
 * ## submitCheckIn
 *
 * The only path by which an attendance record can come into existence.
 *
 * What it checks, and why:
 *  - **App Check + Auth** — proves the call came from the real app binary and a
 *    signed-in user; `employeeId` is taken from the auth token, never the body,
 *    so nobody can punch in on someone else's behalf.
 *  - **Device binding** — the device id must match the employee's registered,
 *    admin-approved device. A device bound to another employee is the classic
 *    buddy-punching signal, so it is always flagged.
 *  - **Liveness challenge** — a server-issued, single-use, 90-second prompt,
 *    verified against the raw ML Kit frame telemetry. Defeats a photo or a
 *    pre-recorded video.
 *  - **Face match** — pluggable vendor, two thresholds: below `review` rejects,
 *    between `review` and `approve` records but flags for a human.
 *  - **Geofence (onsite only)** — Haversine distance against the site radius,
 *    with the GPS accuracy circle as grace. `isFromMockProvider` rejects
 *    outright: a spoofed fix is intent, not error.
 *  - **Server clock** — `timestamp` is `Timestamp.now()` on the server. A client
 *    supplied time is never read, so back-dating is impossible.
 *  - **Idempotency** — `clientNonce` is unique per attempt, so the offline queue
 *    can retry safely without creating duplicate punches.
 *
 * Returns only the outcome. The client receives no writable handle to the record.
 */
export const submitCheckIn = onCall(
  { region: REGION, memory: '512MiB', timeoutSeconds: 60 },
  async (req): Promise<CheckInResponse> => {
    const employeeId = requireAuth(req);
    const db = admin.firestore();
    const data = req.data ?? {};

    // ---- 1. Validate the payload -------------------------------------
    const type = requireEnum<AttendanceType>(data.type, 'type', ['onsite', 'wfh']);
    // Defaults to 'in' so a client that predates checkout keeps working.
    const direction = requireEnum<AttendanceDirection>(
      data.direction ?? 'in',
      'direction',
      ['in', 'out', 'break_start', 'break_end'],
    );
    const deviceId = requireString(data.deviceId, 'deviceId', { maxLength: 128 });
    const challengeId = requireString(data.challengeId, 'challengeId', { maxLength: 128 });
    const clientNonce = requireString(data.clientNonce, 'clientNonce', { maxLength: 128 });
    const selfie = decodeSelfie(data.selfieBase64);
    const siteId = type === 'onsite'
      ? requireString(data.siteId, 'siteId', { maxLength: 128 })
      : null;

    const latitude = optionalNumber(data.latitude, 'latitude');
    const longitude = optionalNumber(data.longitude, 'longitude');
    const accuracyMeters = optionalNumber(data.accuracyMeters, 'accuracyMeters');
    const isFromMockProvider = requireBool(data.isFromMockProvider, 'isFromMockProvider', false);
    const deviceCompromised = requireBool(data.deviceCompromised, 'deviceCompromised', false);
    const liveness = parseLiveness(data.livenessEvidence);

    const location =
      latitude !== null && longitude !== null ? { latitude, longitude } : null;
    if (type === 'onsite' && !location) {
      throw new HttpsError('invalid-argument', 'On-site check-in requires coordinates.');
    }

    // ---- 2. Idempotency ----------------------------------------------
    const existing = await db
      .collection('attendance')
      .where('employeeId', '==', employeeId)
      .where('clientNonce', '==', clientNonce)
      .limit(1)
      .get();
    if (!existing.empty) {
      const prior = existing.docs[0].data() as AttendanceRecord;
      logger.info('Duplicate check-in short-circuited', { employeeId, clientNonce });
      return {
        recordId: existing.docs[0].id,
        direction: prior.direction ?? 'in',
        sessionStatus: 'open',
        workedMinutes: prior.workedMinutes ?? null,
        breakMinutes: prior.breakMinutes ?? null,
        status: prior.status,
        flagReason: prior.flagReason,
        message: 'This check-in was already recorded.',
        distanceFromSiteMeters: prior.distanceFromSite,
        serverTimestampIso: prior.timestamp.toDate().toISOString(),
      };
    }

    // ---- 3. Load the trust context -----------------------------------
    const employeeSnap = await db.collection('employees').doc(employeeId).get();
    if (!employeeSnap.exists) {
      throw new HttpsError('not-found', 'Employee record not found. Complete enrollment first.');
    }
    const employee = employeeSnap.data() as Employee;
    if (!employee.faceEmbeddingRef) {
      throw new HttpsError('failed-precondition', 'Face enrollment is incomplete.');
    }

    const [siteSnap, deviceSnap, challenge, wfhAuthorised] = await Promise.all([
      siteId ? db.collection('sites').doc(siteId).get() : Promise.resolve(null),
      db.collection('devices').doc(deviceId).get(),
      consumeChallenge(db, challengeId, employeeId),
      type === 'wfh' ? isWfhAuthorisedToday(db, employeeId) : Promise.resolve(false),
    ]);

    const site =
      siteSnap && siteSnap.exists
        ? ({ id: siteSnap.id, ...(siteSnap.data() as Site) })
        : null;

    const deviceData = deviceSnap.exists ? (deviceSnap.data() ?? null) : null;
    const deviceApproved = deviceData ? Boolean(deviceData.approved) : null;
    const deviceBoundToOtherEmployee =
      deviceData !== null && deviceData.employeeId !== employeeId;

    // ---- 4. Face match ------------------------------------------------
    const matcher = getFaceMatcher();
    let faceMatch;
    try {
      faceMatch = await matcher.match(employee.faceEmbeddingRef, selfie);
    } catch (err) {
      // Fail closed: a vendor outage must not become a free approval.
      logger.error('Face match provider failed', { employeeId, err });
      throw new HttpsError('unavailable', 'Identity verification is temporarily unavailable.');
    }

    // ---- 5. Decide ----------------------------------------------------
    const decision: Decision = evaluateCheckIn({
      type,
      employeeStatus: employee.status,
      assignedSiteIds: employee.assignedSiteIds ?? [],
      siteId,
      site,
      location,
      accuracyMeters,
      isFromMockProvider,
      deviceId,
      registeredDeviceId: employee.registeredDeviceId,
      deviceApproved,
      deviceBoundToOtherEmployee,
      deviceCompromised,
      faceMatch,
      liveness,
      challenge,
      nowMs: Date.now(),
      wfhAuthorisedToday: wfhAuthorised,
    });

    // ---- 6. Working-day state ------------------------------------------
    // Runs after verification: an unverified punch must not move the clock, so
    // a rejected capture leaves the session exactly as it was.
    const timestamp = Timestamp.now();
    const nowMs = timestamp.toMillis();
    const recordRef = db.collection('attendance').doc();

    let sessionOutcome: DirectionOutcome | null = null;
    let sessionId: string | null = null;

    if (decision.status !== 'rejected') {
      const applied = await applySessionTransition({
        db,
        employeeId,
        direction,
        nowMs,
        recordId: recordRef.id,
      });
      sessionOutcome = applied.outcome;
      sessionId = applied.sessionId;

      // An illegal transition (checking out without checking in, say) turns
      // the whole punch into a rejection, even though verification passed.
      if (!applied.outcome.allowed) {
        const reason = applied.outcome.rejectReason!;
        decision.status = 'rejected';
        decision.flagReason = reason;
        decision.allFlagReasons = [...decision.allFlagReasons, reason];
        decision.message = messageFor(reason);
      } else if (applied.outcome.flags.length > 0) {
        // Late checkout / break overrun / overtime: recorded, not blocked.
        decision.allFlagReasons = [
          ...decision.allFlagReasons,
          ...applied.outcome.flags,
        ];
        if (decision.status === 'approved') {
          decision.status = 'flagged';
          decision.flagReason = applied.outcome.flags[0];
        }
        decision.message = messageFor(applied.outcome.flags[0]);
      } else {
        decision.message = directionMessage(direction, applied.outcome);
      }
    }

    // ---- 7. Persist ---------------------------------------------------

    // Rejected attempts still get an audit selfie: a failed spoof is exactly
    // the evidence a security review needs.
    const selfieStorageRef = await storeSelfie(employeeId, recordRef.id, selfie);

    const record: AttendanceRecord = {
      employeeId,
      type,
      direction,
      sessionId,
      workedMinutes: sessionOutcome?.workedMinutes ?? null,
      breakMinutes: sessionOutcome?.breakMinutes ?? null,
      timestamp,
      faceMatchScore: faceMatch.score,
      gpsCoordinates: location
        ? new GeoPoint(location.latitude, location.longitude)
        : null,
      gpsAccuracyMeters: accuracyMeters,
      siteId,
      distanceFromSite: decision.distanceFromSiteMeters,
      isMockLocationFlag: isFromMockProvider,
      deviceId,
      deviceTrusted: decision.deviceTrusted,
      selfieStorageRef,
      status: decision.status,
      flagReason: decision.flagReason,
      allFlagReasons: decision.allFlagReasons,
      clientNonce,
      anomalyReviewed: false,
    };

    await recordRef.set({
      ...record,
      faceMatchProvider: faceMatch.provider,
      dayKey: dayKey(timestamp.toDate()),
    });

    logger.info('Check-in evaluated', {
      employeeId,
      recordId: recordRef.id,
      status: decision.status,
      reasons: decision.allFlagReasons,
    });

    return {
      recordId: recordRef.id,
      direction,
      sessionStatus: sessionOutcome?.nextStatus ?? 'none',
      workedMinutes: sessionOutcome?.workedMinutes ?? null,
      breakMinutes: sessionOutcome?.breakMinutes ?? null,
      status: decision.status,
      flagReason: decision.flagReason,
      message: decision.message,
      distanceFromSiteMeters: decision.distanceFromSiteMeters,
      serverTimestampIso: timestamp.toDate().toISOString(),
    };
  },
);

const SESSIONS = 'work_sessions';

/**
 * Applies a punch to the employee's open working day, in one transaction.
 *
 * The transaction is what makes the hours trustworthy: two taps racing each
 * other cannot both open a session or both close one, so the arrival and
 * departure times can never be doubled or lost.
 *
 * The open session is found through a pointer on the employee document rather
 * than a query, so an overnight shift stays one session instead of splitting at
 * midnight — and it costs no extra read, since the employee doc is already
 * loaded for verification.
 */
async function applySessionTransition(input: {
  db: FirebaseFirestore.Firestore;
  employeeId: string;
  direction: AttendanceDirection;
  nowMs: number;
  recordId: string;
}): Promise<{ outcome: DirectionOutcome; sessionId: string | null }> {
  const { db, employeeId, direction, nowMs, recordId } = input;
  const employeeRef = db.collection('employees').doc(employeeId);

  return db.runTransaction(async (tx) => {
    const employeeSnap = await tx.get(employeeRef);
    const openSessionId = (employeeSnap.data()?.openSessionId as string) ?? null;

    let stored: WorkSession | null = null;
    let sessionRef: FirebaseFirestore.DocumentReference | null = null;
    if (openSessionId) {
      sessionRef = db.collection(SESSIONS).doc(openSessionId);
      const snap = await tx.get(sessionRef);
      // A dangling pointer (session deleted) is treated as "not checked in"
      // rather than crashing the punch.
      stored = snap.exists ? (snap.data() as WorkSession) : null;
      if (!stored) sessionRef = null;
    }

    const view: SessionView | null =
      stored && stored.status !== 'closed'
        ? {
            checkInAtMs: stored.checkInAtMs,
            status: stored.status,
            breaks: stored.breaks ?? [],
          }
        : null;

    const outcome = evaluateDirection({ direction, session: view, nowMs });
    if (!outcome.allowed) return { outcome, sessionId: openSessionId };

    if (direction === 'in') {
      const day = dayKey(new Date(nowMs));
      const newRef = db.collection(SESSIONS).doc(`${employeeId}_${day}_${nowMs}`);
      const session: WorkSession = {
        employeeId,
        dayKey: day,
        checkInAtMs: nowMs,
        checkInRecordId: recordId,
        checkOutAtMs: null,
        checkOutRecordId: null,
        breaks: [],
        status: 'open',
        totalBreakMinutes: 0,
        workedMinutes: null,
        flags: [],
      };
      tx.set(newRef, session);
      tx.update(employeeRef, { openSessionId: newRef.id });
      return { outcome, sessionId: newRef.id };
    }

    const next = applyDirection({
      session: stored!,
      direction,
      outcome,
      nowMs,
      recordId,
    });
    tx.set(sessionRef!, next);
    if (direction === 'out') {
      // Clearing the pointer is what lets the next check-in start a new day.
      tx.update(employeeRef, { openSessionId: null });
    }
    return { outcome, sessionId: sessionRef!.id };
  });
}

/**
 * Atomically mark the challenge used and return it.
 *
 * The transaction is what makes it single-use: two concurrent submissions
 * cannot both consume the same prompt, so a replayed capture loses the race.
 */
async function consumeChallenge(
  db: FirebaseFirestore.Firestore,
  challengeId: string,
  employeeId: string,
): Promise<LivenessChallenge | null> {
  const ref = db.collection(CHALLENGES_COLLECTION).doc(challengeId);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return null;
    const challenge = snap.data() as LivenessChallenge;
    // A challenge issued to someone else is indistinguishable from an attack.
    if (challenge.employeeId !== employeeId) return null;

    const wasConsumed = challenge.consumed === true;
    if (!wasConsumed) {
      tx.update(ref, { consumed: true, consumedAtMs: Date.now() });
    }
    return { ...challenge, consumed: wasConsumed };
  });
}

/** A WFH punch is only valid on a day someone approved for WFH. */
async function isWfhAuthorisedToday(
  db: FirebaseFirestore.Firestore,
  employeeId: string,
): Promise<boolean> {
  const today = dayKey(new Date());
  const snap = await db
    .collection('wfh_exceptions')
    .where('employeeId', '==', employeeId)
    .where('date', '==', today)
    .limit(1)
    .get();
  return !snap.empty;
}

async function storeSelfie(
  employeeId: string,
  recordId: string,
  selfie: Buffer,
): Promise<string | null> {
  try {
    const bucket = admin.storage().bucket(config.storageBucket);
    const path = `attendance_selfies/${employeeId}/${recordId}.jpg`;
    await bucket.file(path).save(selfie, {
      contentType: 'image/jpeg',
      metadata: { cacheControl: 'private, max-age=0' },
    });
    return path;
  } catch (err) {
    // Losing the audit image must not lose the decision.
    logger.error('Selfie upload failed', { employeeId, recordId, err });
    return null;
  }
}

function parseLiveness(value: unknown): LivenessEvidence {
  const v = (value ?? {}) as Record<string, unknown>;
  const num = (key: string, fallback: number): number =>
    typeof v[key] === 'number' && Number.isFinite(v[key]) ? (v[key] as number) : fallback;

  const actions = Array.isArray(v.completedActions)
    ? (v.completedActions as unknown[])
        .filter((a): a is string => typeof a === 'string')
        .slice(0, 8)
    : [];

  return {
    completedActions: actions,
    framesAnalysed: num('framesAnalysed', 0),
    maxLeftEyeOpenProb: num('maxLeftEyeOpenProb', 0),
    minLeftEyeOpenProb: num('minLeftEyeOpenProb', 1),
    maxHeadEulerAngleY: num('maxHeadEulerAngleY', 0),
    minHeadEulerAngleY: num('minHeadEulerAngleY', 0),
    faceDetected: v.faceDetected === true,
  };
}

export const __testing = { consumeChallenge, parseLiveness };
export type { FlagReason };
