import * as admin from 'firebase-admin';
import { FieldValue, Timestamp } from 'firebase-admin/firestore';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import * as logger from 'firebase-functions/logger';
import { config, REGION } from './config';
import { impliedSpeedKmh } from './lib/geo';
import { days } from './lib/time';
import { FlagReason, GeoPoint } from './types';

/**
 * ## flagAnomalies (scheduled, daily)
 *
 * Per-check-in verification can only see one moment. This sweep looks at the
 * shape of a week and catches what a single request cannot:
 *
 *  - **Replayed face scores** — a real camera never produces the identical
 *    match score on three different days. Identical scores mean the same bytes
 *    were submitted repeatedly, i.e. a captured request being replayed.
 *  - **Impossible travel** — two approved check-ins whose separation implies
 *    faster-than-airliner movement. One of them was not where it claimed.
 *  - **Device drift** — a device id that appears under more than one employee
 *    inside the window: one handset punching for several people.
 *
 * It never deletes or reverses a record. It downgrades the status to `flagged`
 * with a reason and leaves the decision to a human, because every one of these
 * signals has an innocent explanation often enough to matter.
 */
export const flagAnomalies = onSchedule(
  { region: REGION, schedule: 'every day 02:00', timeZone: config.timezone, memory: '512MiB' },
  async () => {
    const db = admin.firestore();
    const since = Timestamp.fromMillis(
      Date.now() - days(config.anomaly.lookbackDays),
    );

    const snap = await db
      .collection('attendance')
      .where('timestamp', '>=', since)
      .orderBy('timestamp', 'asc')
      .get();

    const records: AnomalyRecord[] = snap.docs.map((d) => {
      const data = d.data();
      const gps = data.gpsCoordinates as FirebaseFirestore.GeoPoint | null;
      return {
        id: d.id,
        employeeId: data.employeeId,
        deviceId: data.deviceId,
        status: data.status,
        faceMatchScore: data.faceMatchScore ?? 0,
        timestampMs: (data.timestamp as FirebaseFirestore.Timestamp).toMillis(),
        dayKey: data.dayKey ?? '',
        location: gps ? { latitude: gps.latitude, longitude: gps.longitude } : null,
      };
    });

    const findings = detectAnomalies(records);
    if (findings.size === 0) {
      logger.info('Anomaly sweep clean', { scanned: records.length });
      return;
    }

    const batch = db.batch();
    for (const [recordId, reasons] of findings) {
      batch.update(db.collection('attendance').doc(recordId), {
        status: 'flagged',
        flagReason: reasons[0],
        allFlagReasons: FieldValue.arrayUnion(...reasons),
        anomalyReviewed: false,
        anomalyDetectedAt: Timestamp.now(),
      });
    }
    await batch.commit();

    logger.warn('Anomalies flagged', { scanned: records.length, flagged: findings.size });
  },
);

export interface AnomalyRecord {
  id: string;
  employeeId: string;
  deviceId: string;
  status: string;
  faceMatchScore: number;
  timestampMs: number;
  dayKey: string;
  location: GeoPoint | null;
}

/**
 * Pure detection pass over a window of records.
 *
 * Separated from the scheduled wrapper so the patterns can be unit tested with
 * hand-built histories instead of a live Firestore.
 */
export function detectAnomalies(
  records: AnomalyRecord[],
): Map<string, FlagReason[]> {
  const findings = new Map<string, FlagReason[]>();
  const add = (id: string, reason: FlagReason) => {
    const list = findings.get(id) ?? [];
    if (!list.includes(reason)) list.push(reason);
    findings.set(id, list);
  };

  const byEmployee = groupBy(records, (r) => r.employeeId);

  for (const [, history] of byEmployee) {
    const chronological = [...history].sort((a, b) => a.timestampMs - b.timestampMs);

    // --- replayed face scores ---------------------------------------
    const byScore = groupBy(
      chronological.filter((r) => r.faceMatchScore > 0),
      (r) => quantiseScore(r.faceMatchScore),
    );
    for (const [, sameScore] of byScore) {
      const distinctDays = new Set(sameScore.map((r) => r.dayKey || dayOf(r.timestampMs)));
      if (distinctDays.size >= config.anomaly.identicalScoreDayThreshold) {
        sameScore.forEach((r) => add(r.id, FlagReason.ReplayedFaceScore));
      }
    }

    // --- impossible travel ------------------------------------------
    for (let i = 1; i < chronological.length; i++) {
      const prev = chronological[i - 1];
      const curr = chronological[i];
      if (!prev.location || !curr.location) continue;
      const speed = impliedSpeedKmh(
        prev.location,
        curr.location,
        curr.timestampMs - prev.timestampMs,
      );
      if (speed > config.geo.impossibleTravelKmh) {
        add(curr.id, FlagReason.ImpossibleTravel);
        add(prev.id, FlagReason.ImpossibleTravel);
      }
    }
  }

  // --- a device serving multiple employees ---------------------------
  const byDevice = groupBy(records, (r) => r.deviceId);
  for (const [, onDevice] of byDevice) {
    const employees = new Set(onDevice.map((r) => r.employeeId));
    if (employees.size > 1) {
      onDevice.forEach((r) => add(r.id, FlagReason.DeviceSharedAcrossEmployees));
    }
  }

  return findings;
}

/** Bucket scores so float noise does not hide an exact-match replay. */
function quantiseScore(score: number): string {
  const eps = config.anomaly.identicalScoreEpsilon || 1e-4;
  return String(Math.round(score / eps));
}

function dayOf(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

function groupBy<T, K>(items: T[], key: (item: T) => K): Map<K, T[]> {
  const map = new Map<K, T[]>();
  for (const item of items) {
    const k = key(item);
    const list = map.get(k);
    if (list) list.push(item);
    else map.set(k, [item]);
  }
  return map;
}
