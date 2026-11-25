import * as admin from 'firebase-admin';
import { Timestamp } from 'firebase-admin/firestore';
import { HttpsError, onCall } from 'firebase-functions/v2/https';
import * as logger from 'firebase-functions/logger';
import { REGION } from './config';
import { requireAdmin, requireBool, requireString } from './lib/guards';

/**
 * ## reviewAttendanceRecord (admin only)
 *
 * Closes out a flagged record.
 *
 * Even an administrator goes through a Cloud Function: the rules deny client
 * writes to `attendance` for everyone, which means there is exactly one code
 * path that can modify an attendance record, and it is auditable. Accepting a
 * flagged punch records WHO accepted it and leaves the original flag reasons
 * in place, so the history cannot be quietly rewritten.
 */
export const reviewAttendanceRecord = onCall({ region: REGION }, async (req) => {
  const adminUid = requireAdmin(req);
  const recordId = requireString(req.data?.recordId, 'recordId', { maxLength: 128 });
  const accepted = requireBool(req.data?.accepted, 'accepted');
  const note =
    req.data?.note === undefined || req.data?.note === null
      ? null
      : requireString(req.data.note, 'note', { maxLength: 1000 });

  const ref = admin.firestore().collection('attendance').doc(recordId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError('not-found', 'Attendance record not found.');

  await ref.update({
    anomalyReviewed: true,
    reviewedBy: adminUid,
    reviewedAt: Timestamp.now(),
    reviewOutcome: accepted ? 'accepted' : 'upheld',
    reviewNote: note,
    // `status` moves to approved only on an explicit accept; flagReason and
    // allFlagReasons are never cleared, so the audit trail survives.
    ...(accepted ? { status: 'approved' } : {}),
  });

  logger.info('Flagged record reviewed', { recordId, adminUid, accepted });
  return { recordId, reviewed: true, accepted };
});
