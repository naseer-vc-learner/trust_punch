import * as admin from 'firebase-admin';
import { Timestamp } from 'firebase-admin/firestore';
import { HttpsError, onCall } from 'firebase-functions/v2/https';
import * as logger from 'firebase-functions/logger';
import { REGION } from './config';
import { requireAdmin, requireAuth, requireBool, requireString } from './lib/guards';
import { Employee } from './types';

/**
 * ## registerDevice
 *
 * Records a device request and returns. It never grants trust.
 *
 * Why manual approval: device binding is the control that stops one phone
 * punching in for five people. If the app could self-register a device,
 * that control would be worth nothing — anyone with a stolen password could
 * enroll their own handset. So the record is written with `approved: false`,
 * an admin notification is queued, and check-ins from the device are flagged
 * (not silently accepted) until a human approves it.
 *
 * The first device of a never-enrolled employee is auto-approved, because at
 * that point there is nothing yet to defend and enrollment already happened
 * in person.
 */
export const registerDevice = onCall({ region: REGION }, async (req) => {
  const employeeId = requireAuth(req);
  const db = admin.firestore();
  const data = req.data ?? {};

  const deviceId = requireString(data.deviceId, 'deviceId', { maxLength: 128 });
  const platform = requireString(data.platform, 'platform', { maxLength: 32 });
  const model = requireString(data.model, 'model', { maxLength: 128 });
  const compromised = requireBool(data.compromised, 'compromised', false);

  if (compromised) {
    throw new HttpsError(
      'failed-precondition',
      'This device appears rooted or jailbroken and cannot be registered.',
    );
  }

  const employeeRef = db.collection('employees').doc(employeeId);
  const employeeSnap = await employeeRef.get();
  if (!employeeSnap.exists) {
    throw new HttpsError('not-found', 'Employee record not found.');
  }
  const employee = employeeSnap.data() as Employee;

  const deviceRef = db.collection('devices').doc(deviceId);
  const existing = await deviceRef.get();
  if (existing.exists && existing.data()?.employeeId !== employeeId) {
    // Do not overwrite: that is exactly how a shared handset would launder
    // itself from one employee to the next.
    logger.warn('Device claim conflict', { deviceId, employeeId });
    throw new HttpsError(
      'already-exists',
      'This device is registered to another employee. Contact your administrator.',
    );
  }
  if (existing.exists && existing.data()?.approved === true) {
    // Re-point the employee at this device if they are not already on it.
    // Without this, an employee whose `registeredDeviceId` was cleared (an
    // admin reset, a re-provision) could never get back to trusted: the device
    // is approved, so registration short-circuits here, but verification keeps
    // flagging every punch as UNREGISTERED_DEVICE with no way out.
    if (employee.registeredDeviceId !== deviceId) {
      await employeeRef.update({ registeredDeviceId: deviceId });
      logger.info('Re-pointed employee at approved device', { employeeId, deviceId });
    }
    return { status: 'approved', deviceId, autoApproved: false };
  }

  const isFirstDevice = !employee.registeredDeviceId;

  await deviceRef.set(
    {
      employeeId,
      platform,
      model,
      approved: isFirstDevice,
      registeredAt: Timestamp.now(),
      ...(isFirstDevice
        ? { approvedBy: 'system:first-device', approvedAt: Timestamp.now() }
        : {}),
    },
    { merge: true },
  );

  if (isFirstDevice) {
    await employeeRef.update({ registeredDeviceId: deviceId });
    return { status: 'approved', deviceId, autoApproved: true };
  }

  await notifyAdmins(db, {
    title: 'Device approval required',
    body: `${employee.name} requested a new device (${model}).`,
    data: { kind: 'device_approval', deviceId, employeeId },
  });

  return { status: 'pending', deviceId, autoApproved: false };
});

/**
 * ## approveDevice (admin only)
 *
 * Flips a pending device to trusted and re-points the employee's
 * `registeredDeviceId`. Both writes happen in one batch so an employee can
 * never end up with an approved device that is not their registered one.
 */
export const approveDevice = onCall({ region: REGION }, async (req) => {
  const adminUid = requireAdmin(req);
  const db = admin.firestore();

  const deviceId = requireString(req.data?.deviceId, 'deviceId', { maxLength: 128 });
  const approve = requireBool(req.data?.approve, 'approve');

  const deviceRef = db.collection('devices').doc(deviceId);
  const snap = await deviceRef.get();
  if (!snap.exists) throw new HttpsError('not-found', 'Device not found.');

  const employeeId = snap.data()?.employeeId as string;
  const batch = db.batch();

  batch.update(deviceRef, {
    approved: approve,
    approvedBy: adminUid,
    approvedAt: Timestamp.now(),
  });
  if (approve) {
    batch.update(db.collection('employees').doc(employeeId), {
      registeredDeviceId: deviceId,
    });
  }
  await batch.commit();

  logger.info('Device approval decided', { deviceId, employeeId, approve, adminUid });
  return { status: approve ? 'approved' : 'rejected', deviceId };
});

/** Push to every admin's registered FCM tokens. Best-effort by design. */
export async function notifyAdmins(
  db: FirebaseFirestore.Firestore,
  message: { title: string; body: string; data?: Record<string, string> },
): Promise<void> {
  const admins = await db.collection('employees').where('role', '==', 'admin').get();
  const tokens = admins.docs.flatMap((d) => (d.data().fcmTokens as string[]) ?? []);
  if (tokens.length === 0) {
    logger.warn('No admin FCM tokens registered; notification skipped', message);
    return;
  }
  await admin.messaging().sendEachForMulticast({
    tokens,
    notification: { title: message.title, body: message.body },
    data: message.data ?? {},
  });
}
