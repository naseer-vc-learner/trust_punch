import * as admin from 'firebase-admin';
import { FieldValue, Timestamp } from 'firebase-admin/firestore';
import { HttpsError, onCall } from 'firebase-functions/v2/https';
import * as logger from 'firebase-functions/logger';
import { config, REGION } from './config';
import { getFaceMatcher } from './faceMatch';
import { decodeSelfie, requireAdmin, requireAuth, requireString } from './lib/guards';
import { notifyAdmins } from './devices';

const MIN_FRAMES = 5;
const MAX_FRAMES = 8;

/**
 * ## enrollFace
 *
 * Turns 5–8 captured angles into one identity template.
 *
 * The raw frames are never persisted: they are decoded in memory, handed to the
 * matcher, and dropped when the request ends. Only the opaque `faceEmbeddingRef`
 * survives, so a Firestore or Storage breach does not leak a face photo set.
 *
 * Enrollment is allowed once. Re-enrolling would let an attacker who briefly
 * holds a session replace the stored identity with their own face, so a second
 * attempt requires an admin to clear the existing template first.
 */
export const enrollFace = onCall(
  { region: REGION, memory: '1GiB', timeoutSeconds: 120 },
  async (req) => {
    const employeeId = requireAuth(req);
    const db = admin.firestore();

    const frames = req.data?.framesBase64;
    if (!Array.isArray(frames) || frames.length < MIN_FRAMES || frames.length > MAX_FRAMES) {
      throw new HttpsError(
        'invalid-argument',
        `framesBase64 must contain between ${MIN_FRAMES} and ${MAX_FRAMES} images.`,
      );
    }

    const employeeRef = db.collection('employees').doc(employeeId);
    const snap = await employeeRef.get();
    if (!snap.exists) throw new HttpsError('not-found', 'Employee record not found.');
    if (snap.data()?.faceEmbeddingRef) {
      throw new HttpsError(
        'already-exists',
        'Face enrollment already exists. An administrator must reset it first.',
      );
    }

    const buffers = frames.map((f) => decodeSelfie(f));
    const matcher = getFaceMatcher();

    // One-to-many search BEFORE storing anything.
    //
    // Per-check-in verification can never catch this: if the same person
    // enrolls as "Ali" and as "Sam", both templates are genuine and both match
    // their own face perfectly every day. The only moment the collision is
    // visible is enrollment, so it has to be caught here or not at all.
    const duplicates = await matcher.findDuplicates(buffers[0], {
      excludeEmployeeId: employeeId,
      threshold: config.face.duplicateThreshold,
    });

    if (duplicates.length > 0) {
      const best = duplicates[0];
      logger.warn('Duplicate face at enrollment', {
        employeeId,
        matchedEmployeeId: best.employeeId,
        score: best.score,
      });

      await db.collection('enrollment_alerts').add({
        employeeId,
        matchedEmployeeId: best.employeeId,
        score: best.score,
        blocked: config.face.blockDuplicateEnrollment,
        createdAt: Timestamp.now(),
        resolved: false,
      });

      await notifyAdmins(db, {
        title: 'Duplicate face detected',
        body: 'An enrollment matched a face already on the roster.',
        data: {
          kind: 'duplicate_face',
          employeeId,
          matchedEmployeeId: best.employeeId,
        },
      });

      if (config.face.blockDuplicateEnrollment) {
        throw new HttpsError(
          'already-exists',
          'This face is already registered to another employee. ' +
            'Contact your administrator.',
        );
      }
    }

    const result = await matcher.enroll(employeeId, buffers);

    await employeeRef.update({
      faceEmbeddingRef: result.embeddingRef,
      faceEnrolledAt: Timestamp.now(),
      faceMatchProvider: result.provider,
      status: 'active',
    });

    logger.info('Face enrolled', {
      employeeId,
      provider: result.provider,
      acceptedFrames: result.acceptedFrames,
    });

    return { enrolled: true, acceptedFrames: result.acceptedFrames };
  },
);

/**
 * ## resetFaceEnrollment (admin only)
 *
 * Deletes the biometric template so the employee can re-enroll — also the
 * GDPR/erasure path, since the template is the only biometric data retained.
 */
export const resetFaceEnrollment = onCall({ region: REGION }, async (req) => {
  const adminUid = requireAdmin(req);
  const employeeId = requireString(req.data?.employeeId, 'employeeId', { maxLength: 128 });
  const db = admin.firestore();

  const ref = db.collection('employees').doc(employeeId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError('not-found', 'Employee record not found.');

  const embeddingRef = snap.data()?.faceEmbeddingRef as string | undefined;
  if (embeddingRef) {
    await getFaceMatcher().deleteEnrollment(embeddingRef);
  }
  await ref.update({
    faceEmbeddingRef: FieldValue.delete(),
    status: 'pending_enrollment',
  });

  logger.info('Face enrollment reset', { employeeId, adminUid });
  return { reset: true };
});

/**
 * ## setAdminClaim (admin only, bootstrap via CLI)
 *
 * Admin identity lives in a custom auth token claim rather than a Firestore
 * field, so the security rules can trust it without a document read and no
 * Firestore write can escalate privilege.
 *
 * Bootstrap the very first admin from a trusted shell:
 *   firebase auth:import / or
 *   `admin.auth().setCustomUserClaims(uid, { admin: true })` in a one-off script.
 */
export const setAdminClaim = onCall({ region: REGION }, async (req) => {
  const callerUid = requireAdmin(req);
  const targetUid = requireString(req.data?.uid, 'uid', { maxLength: 128 });
  const grant = req.data?.admin === true;

  await admin.auth().setCustomUserClaims(targetUid, { admin: grant });
  await admin
    .firestore()
    .collection('employees')
    .doc(targetUid)
    .update({ role: grant ? 'admin' : 'employee' });

  logger.info('Admin claim changed', { targetUid, grant, callerUid });
  return { uid: targetUid, admin: grant };
});

/**
 * ## registerFcmToken
 *
 * Stores the caller's push token so WFH presence pings and admin alerts can
 * reach them. Tokens are appended with `arrayUnion` under the caller's own uid,
 * so nobody can attach a token to another employee and intercept their pings.
 */
export const registerFcmToken = onCall({ region: REGION }, async (req) => {
  const employeeId = requireAuth(req);
  const token = requireString(req.data?.token, 'token', { maxLength: 512 });

  await admin
    .firestore()
    .collection('employees')
    .doc(employeeId)
    .update({ fcmTokens: FieldValue.arrayUnion(token) });

  return { registered: true };
});
