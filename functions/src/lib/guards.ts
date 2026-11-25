import { CallableRequest, HttpsError } from 'firebase-functions/v2/https';
import { config } from '../config';

/**
 * Shared entry checks for every callable.
 *
 * App Check is what stops someone calling `submitCheckIn` with curl from a
 * laptop: without a valid attestation token the request never reaches the
 * verification logic at all.
 */
export function requireAuth(req: CallableRequest): string {
  if (config.requireAppCheck && !req.app) {
    throw new HttpsError(
      'failed-precondition',
      'Request must come from an attested app instance.',
    );
  }
  const uid = req.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in required.');
  }
  return uid;
}

export function requireAdmin(req: CallableRequest): string {
  const uid = requireAuth(req);
  if (req.auth?.token?.admin !== true) {
    throw new HttpsError('permission-denied', 'Admin privilege required.');
  }
  return uid;
}

/** Field-level validation helpers — everything from the client is hostile. */

export function requireString(
  value: unknown,
  field: string,
  { maxLength = 512 }: { maxLength?: number } = {},
): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new HttpsError('invalid-argument', `${field} must be a non-empty string.`);
  }
  if (value.length > maxLength) {
    throw new HttpsError('invalid-argument', `${field} exceeds ${maxLength} characters.`);
  }
  return value;
}

export function optionalNumber(value: unknown, field: string): number | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new HttpsError('invalid-argument', `${field} must be a finite number.`);
  }
  return value;
}

export function requireEnum<T extends string>(
  value: unknown,
  field: string,
  allowed: readonly T[],
): T {
  if (typeof value !== 'string' || !allowed.includes(value as T)) {
    throw new HttpsError(
      'invalid-argument',
      `${field} must be one of: ${allowed.join(', ')}.`,
    );
  }
  return value as T;
}

export function requireBool(value: unknown, field: string, fallback?: boolean): boolean {
  if (value === undefined || value === null) {
    if (fallback !== undefined) return fallback;
    throw new HttpsError('invalid-argument', `${field} is required.`);
  }
  if (typeof value !== 'boolean') {
    throw new HttpsError('invalid-argument', `${field} must be a boolean.`);
  }
  return value;
}

const MAX_SELFIE_BYTES = 4 * 1024 * 1024;

/** Decode and bound-check a base64 image before it touches any vendor SDK. */
export function decodeSelfie(value: unknown): Buffer {
  const raw = requireString(value, 'selfieBase64', { maxLength: 12_000_000 });
  const payload = raw.startsWith('data:') ? raw.slice(raw.indexOf(',') + 1) : raw;
  let buffer: Buffer;
  try {
    buffer = Buffer.from(payload, 'base64');
  } catch {
    throw new HttpsError('invalid-argument', 'selfieBase64 is not valid base64.');
  }
  if (buffer.length === 0) {
    throw new HttpsError('invalid-argument', 'selfieBase64 decoded to zero bytes.');
  }
  if (buffer.length > MAX_SELFIE_BYTES) {
    throw new HttpsError('invalid-argument', 'Selfie exceeds the 4MB limit.');
  }
  if (!looksLikeImage(buffer)) {
    throw new HttpsError('invalid-argument', 'Selfie is not a JPEG or PNG image.');
  }
  return buffer;
}

/** Magic-number sniff — do not trust a client-declared content type. */
export function looksLikeImage(buffer: Buffer): boolean {
  const isJpeg = buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff;
  const isPng =
    buffer[0] === 0x89 &&
    buffer[1] === 0x50 &&
    buffer[2] === 0x4e &&
    buffer[3] === 0x47;
  return isJpeg || isPng;
}
