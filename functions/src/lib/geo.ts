import { GeoPoint } from '../types';

const EARTH_RADIUS_METERS = 6371008.8; // IUGG mean earth radius

const toRadians = (degrees: number): number => (degrees * Math.PI) / 180;

/**
 * Great-circle distance in metres between two coordinates.
 *
 * This is the single most safety-critical arithmetic in the app: if it drifts,
 * geofencing silently stops working and every off-site punch is approved.
 * It is pure, dependency-free and covered by `test/geo.test.ts`.
 */
export function haversineDistanceMeters(a: GeoPoint, b: GeoPoint): number {
  assertValidCoordinate(a);
  assertValidCoordinate(b);

  const dLat = toRadians(b.latitude - a.latitude);
  const dLon = toRadians(b.longitude - a.longitude);
  const lat1 = toRadians(a.latitude);
  const lat2 = toRadians(b.latitude);

  const sinHalfDLat = Math.sin(dLat / 2);
  const sinHalfDLon = Math.sin(dLon / 2);

  const h =
    sinHalfDLat * sinHalfDLat +
    Math.cos(lat1) * Math.cos(lat2) * sinHalfDLon * sinHalfDLon;

  // clamp guards against floating point pushing h just past 1 for antipodes
  return 2 * EARTH_RADIUS_METERS * Math.asin(Math.min(1, Math.sqrt(h)));
}

export class InvalidCoordinateError extends Error {}

export function assertValidCoordinate(point: GeoPoint): void {
  const { latitude, longitude } = point;
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
    throw new InvalidCoordinateError('Coordinate must be a finite number');
  }
  if (latitude < -90 || latitude > 90) {
    throw new InvalidCoordinateError(`Latitude out of range: ${latitude}`);
  }
  if (longitude < -180 || longitude > 180) {
    throw new InvalidCoordinateError(`Longitude out of range: ${longitude}`);
  }
  // 0,0 is in the Gulf of Guinea — in practice it means "the client sent us an
  // uninitialised location object", which must never satisfy a geofence.
  if (latitude === 0 && longitude === 0) {
    throw new InvalidCoordinateError('Null Island coordinate rejected');
  }
}

/** Implied speed between two points, used by impossible-travel detection. */
export function impliedSpeedKmh(
  from: GeoPoint,
  to: GeoPoint,
  elapsedMs: number,
): number {
  if (elapsedMs <= 0) return Number.POSITIVE_INFINITY;
  const meters = haversineDistanceMeters(from, to);
  const hours = elapsedMs / 3_600_000;
  return meters / 1000 / hours;
}
