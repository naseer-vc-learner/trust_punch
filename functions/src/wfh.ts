import { randomInt } from 'crypto';
import * as admin from 'firebase-admin';
import { FieldValue, Timestamp } from 'firebase-admin/firestore';
import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import * as logger from 'firebase-functions/logger';
import { config, REGION } from './config';
import { requireAdmin, requireAuth, requireString } from './lib/guards';
import { dayKey, localWeekday, minutes } from './lib/time';
import { Employee } from './types';

const PINGS = 'presence_pings';
const PLANS = 'presence_ping_plans';

/**
 * ## requestWfhDay / approveWfhDay
 *
 * A WFH day switches off the geofence, so it is a privilege that a manager
 * grants — not a toggle the employee flips for themselves. The request is
 * recorded as pending; only `approveWfhDay` (manager/admin) creates the
 * `wfh_exceptions` document that `submitCheckIn` looks for.
 */
export const requestWfhDay = onCall({ region: REGION }, async (req) => {
  const employeeId = requireAuth(req);
  const date = requireDateKey(req.data?.date);
  const reason = requireString(req.data?.reason, 'reason', { maxLength: 500 });

  const id = `${employeeId}_${date}`;
  await admin.firestore().collection('wfh_requests').doc(id).set({
    employeeId,
    date,
    reason,
    status: 'pending',
    requestedAt: Timestamp.now(),
  });

  return { status: 'pending', date };
});

export const approveWfhDay = onCall({ region: REGION }, async (req) => {
  const approverUid = requireAdmin(req);
  const employeeId = requireString(req.data?.employeeId, 'employeeId', { maxLength: 128 });
  const date = requireDateKey(req.data?.date);
  const reason = requireString(req.data?.reason, 'reason', { maxLength: 500 });

  const db = admin.firestore();
  const id = `${employeeId}_${date}`;

  await db.collection('wfh_exceptions').doc(id).set({
    employeeId,
    date,
    reason,
    approvedBy: approverUid,
    approvedAt: Timestamp.now(),
  });
  await db
    .collection('wfh_requests')
    .doc(id)
    .set({ status: 'approved', decidedBy: approverUid }, { merge: true });

  logger.info('WFH day approved', { employeeId, date, approverUid });
  return { status: 'approved', date };
});

/**
 * ## planPresencePings (scheduled, once per working morning)
 *
 * Picks 2–4 random minutes inside the working day for every employee with an
 * approved WFH exception today, and stores them.
 *
 * Why plan ahead instead of rolling a die on each dispatch tick: an employee
 * who learns the dispatcher fires "sometimes at :00 and :30" can be present
 * only at those moments. Times drawn from the whole day, once, are unguessable
 * from the outside and still evenly spread.
 */
export const planPresencePings = onSchedule(
  {
    region: REGION,
    schedule: `0 ${config.wfh.workDayStartHour} * * *`,
    timeZone: config.timezone,
  },
  async () => {
    const db = admin.firestore();
    const now = new Date();
    const weekday = localWeekday(now);
    if (weekday === 0 || weekday === 6) {
      logger.info('Weekend — no presence pings planned');
      return;
    }

    const today = dayKey(now);
    const exceptions = await db
      .collection('wfh_exceptions')
      .where('date', '==', today)
      .get();

    const dayStartMs = startOfLocalHour(now, config.wfh.workDayStartHour);
    const windowMinutes =
      (config.wfh.workDayEndHour - config.wfh.workDayStartHour) * 60 -
      config.wfh.responseWindowMinutes;

    const batch = db.batch();
    for (const doc of exceptions.docs) {
      const employeeId = doc.data().employeeId as string;
      const count = randomInt(config.wfh.minPingsPerDay, config.wfh.maxPingsPerDay + 1);
      const offsets = pickDistinctMinutes(count, windowMinutes);
      batch.set(db.collection(PLANS).doc(`${employeeId}_${today}`), {
        employeeId,
        date: today,
        dueAtMs: offsets.map((m) => dayStartMs + minutes(m)),
        sent: [],
      });
    }
    await batch.commit();
    logger.info('Presence pings planned', { date: today, employees: exceptions.size });
  },
);

/**
 * ## dispatchPresencePings (scheduled, every 5 minutes)
 *
 * Sends any planned ping whose time has arrived, writes a `presence_pings`
 * record with a hard deadline, and closes out any window that elapsed without
 * a response. A missed ping is evidence, not a punishment — it lands in the
 * flagged queue for a manager to interpret.
 */
export const dispatchPresencePings = onSchedule(
  { region: REGION, schedule: 'every 5 minutes', timeZone: config.timezone },
  async () => {
    const db = admin.firestore();
    const nowMs = Date.now();
    const today = dayKey(new Date());

    const plans = await db.collection(PLANS).where('date', '==', today).get();

    for (const plan of plans.docs) {
      const { employeeId, dueAtMs = [], sent = [] } = plan.data() as {
        employeeId: string;
        dueAtMs: number[];
        sent: number[];
      };
      const due = dueAtMs.filter((t) => t <= nowMs && !sent.includes(t));
      if (due.length === 0) continue;

      for (const slot of due) {
        await issuePing(db, employeeId, slot, nowMs);
      }
      await plan.ref.update({
        sent: FieldValue.arrayUnion(...due),
      });
    }

    await closeExpiredPings(db, nowMs);
  },
);

async function issuePing(
  db: FirebaseFirestore.Firestore,
  employeeId: string,
  slotMs: number,
  nowMs: number,
): Promise<void> {
  const expiresAtMs = nowMs + minutes(config.wfh.responseWindowMinutes);
  const ref = await db.collection(PINGS).add({
    employeeId,
    slotMs,
    issuedAt: Timestamp.fromMillis(nowMs),
    expiresAtMs,
    status: 'pending',
    date: dayKey(new Date(nowMs)),
  });

  const employeeSnap = await db.collection('employees').doc(employeeId).get();
  const tokens = ((employeeSnap.data() as Employee | undefined)?.fcmTokens ?? []).filter(
    Boolean,
  );
  if (tokens.length === 0) {
    logger.warn('Presence ping has no delivery target', { employeeId });
    return;
  }

  await admin.messaging().sendEachForMulticast({
    tokens,
    notification: {
      title: 'Presence check',
      body: `Confirm you are working — ${config.wfh.responseWindowMinutes} minutes to respond.`,
    },
    data: { kind: 'presence_ping', pingId: ref.id, expiresAtMs: String(expiresAtMs) },
    android: { priority: 'high' },
    apns: { payload: { aps: { contentAvailable: true, sound: 'default' } } },
  });
}

async function closeExpiredPings(
  db: FirebaseFirestore.Firestore,
  nowMs: number,
): Promise<void> {
  const stale = await db
    .collection(PINGS)
    .where('status', '==', 'pending')
    .where('expiresAtMs', '<', nowMs)
    .limit(200)
    .get();
  if (stale.empty) return;

  const batch = db.batch();
  stale.docs.forEach((d) => batch.update(d.ref, { status: 'missed' }));
  await batch.commit();
  logger.info('Presence pings expired', { count: stale.size });
}

/**
 * ## respondToPresencePing
 *
 * The response is a full face capture routed through the same verification
 * path as a check-in, because a ping answered by tapping "yes" would prove
 * only that a phone was unlocked.
 */
export const respondToPresencePing = onCall({ region: REGION }, async (req) => {
  const employeeId = requireAuth(req);
  const pingId = requireString(req.data?.pingId, 'pingId', { maxLength: 128 });
  const recordId = requireString(req.data?.attendanceRecordId, 'attendanceRecordId', {
    maxLength: 128,
  });
  const db = admin.firestore();

  const pingRef = db.collection(PINGS).doc(pingId);
  const snap = await pingRef.get();
  if (!snap.exists) throw new HttpsError('not-found', 'Ping not found.');

  const ping = snap.data() as { employeeId: string; expiresAtMs: number; status: string };
  if (ping.employeeId !== employeeId) {
    throw new HttpsError('permission-denied', 'This ping belongs to another employee.');
  }
  if (ping.status !== 'pending') {
    throw new HttpsError('failed-precondition', `Ping already ${ping.status}.`);
  }
  if (Date.now() > ping.expiresAtMs) {
    await pingRef.update({ status: 'missed' });
    throw new HttpsError('deadline-exceeded', 'The response window has closed.');
  }

  // The verification already happened in submitCheckIn; we only accept its
  // verdict here, and only if that record actually belongs to this employee.
  const recordSnap = await db.collection('attendance').doc(recordId).get();
  const record = recordSnap.data();
  if (!recordSnap.exists || record?.employeeId !== employeeId) {
    throw new HttpsError('invalid-argument', 'Unknown attendance record.');
  }

  const answered = record?.status === 'approved';
  await pingRef.update({
    status: answered ? 'answered' : 'failed',
    respondedAt: Timestamp.now(),
    attendanceRecordId: recordId,
  });

  return { status: answered ? 'answered' : 'failed' };
});

/** `YYYY-MM-DD`, validated so a malformed key cannot widen a query. */
function requireDateKey(value: unknown): string {
  const date = requireString(value, 'date', { maxLength: 10 });
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    throw new HttpsError('invalid-argument', 'date must be YYYY-MM-DD.');
  }
  return date;
}

/**
 * Epoch ms of `hour:00` on `reference`'s local date, in the configured timezone.
 *
 * Done by offset correction rather than string arithmetic so it stays right
 * across DST transitions — the second pass re-reads the offset at the corrected
 * instant, which is what fixes the hour on a changeover day.
 */
export function startOfLocalHour(
  reference: Date,
  hour: number,
  timezone: string = config.timezone,
): number {
  const [y, m, d] = dayKey(reference, timezone).split('-').map(Number);
  const wallClockAsUtc = Date.UTC(y, m - 1, d, hour, 0, 0, 0);
  let instant = wallClockAsUtc - tzOffsetMs(wallClockAsUtc, timezone);
  instant = wallClockAsUtc - tzOffsetMs(instant, timezone);
  return instant;
}

/** How far the zone is ahead of UTC at a given instant, in ms. */
function tzOffsetMs(utcMs: number, timezone: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    hour12: false,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).formatToParts(new Date(utcMs));
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value);
  // Intl renders midnight as hour 24 in some ICU versions; normalise it.
  const hour = get('hour') % 24;
  const asUtc = Date.UTC(get('year'), get('month') - 1, get('day'), hour, get('minute'), get('second'));
  return asUtc - utcMs;
}

/** `count` distinct minute offsets in [0, span), no clustering guarantee. */
export function pickDistinctMinutes(count: number, span: number): number[] {
  const picked = new Set<number>();
  const safeCount = Math.min(count, Math.max(1, span));
  while (picked.size < safeCount) {
    picked.add(randomInt(Math.max(1, span)));
  }
  return [...picked].sort((a, b) => a - b);
}
