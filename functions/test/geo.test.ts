import { describe, expect, it } from 'vitest';
import {
  haversineDistanceMeters,
  impliedSpeedKmh,
  InvalidCoordinateError,
} from '../src/lib/geo';

const DUBAI_MALL = { latitude: 25.1972, longitude: 55.2744 };
const BURJ_AL_ARAB = { latitude: 25.1412, longitude: 55.1853 };

describe('haversineDistanceMeters', () => {
  it('is zero for identical points', () => {
    expect(haversineDistanceMeters(DUBAI_MALL, DUBAI_MALL)).toBe(0);
  });

  it('matches a known distance within 0.5%', () => {
    // Dubai Mall -> Burj Al Arab is ~10.9 km great-circle.
    const d = haversineDistanceMeters(DUBAI_MALL, BURJ_AL_ARAB);
    expect(d).toBeGreaterThan(10_800);
    expect(d).toBeLessThan(11_100);
  });

  it('is symmetric', () => {
    expect(haversineDistanceMeters(DUBAI_MALL, BURJ_AL_ARAB)).toBeCloseTo(
      haversineDistanceMeters(BURJ_AL_ARAB, DUBAI_MALL),
      6,
    );
  });

  it('handles one degree of latitude (~111.2 km)', () => {
    const d = haversineDistanceMeters(
      { latitude: 0.5, longitude: 10 },
      { latitude: 1.5, longitude: 10 },
    );
    expect(d).toBeGreaterThan(111_000);
    expect(d).toBeLessThan(111_400);
  });

  it('handles the antimeridian without blowing up', () => {
    const d = haversineDistanceMeters(
      { latitude: 10, longitude: 179.9 },
      { latitude: 10, longitude: -179.9 },
    );
    // 0.2 degrees of longitude at 10N is ~22 km, NOT most of the planet.
    expect(d).toBeLessThan(25_000);
  });

  it('handles antipodes without NaN from float overshoot', () => {
    const d = haversineDistanceMeters(
      { latitude: 10, longitude: 20 },
      { latitude: -10, longitude: -160 },
    );
    expect(Number.isFinite(d)).toBe(true);
    expect(d).toBeGreaterThan(19_000_000);
  });

  it('rejects Null Island, which is what an uninitialised fix looks like', () => {
    expect(() =>
      haversineDistanceMeters({ latitude: 0, longitude: 0 }, DUBAI_MALL),
    ).toThrow(InvalidCoordinateError);
  });

  it('rejects out-of-range and non-finite coordinates', () => {
    expect(() => haversineDistanceMeters({ latitude: 91, longitude: 0 }, DUBAI_MALL)).toThrow();
    expect(() => haversineDistanceMeters({ latitude: 0, longitude: 181 }, DUBAI_MALL)).toThrow();
    expect(() =>
      haversineDistanceMeters({ latitude: NaN, longitude: 0 }, DUBAI_MALL),
    ).toThrow();
  });
});

describe('impliedSpeedKmh', () => {
  it('computes a plausible commute speed', () => {
    const speed = impliedSpeedKmh(DUBAI_MALL, BURJ_AL_ARAB, 30 * 60_000);
    expect(speed).toBeGreaterThan(20);
    expect(speed).toBeLessThan(25);
  });

  it('treats a zero or negative gap as infinite speed', () => {
    expect(impliedSpeedKmh(DUBAI_MALL, BURJ_AL_ARAB, 0)).toBe(Infinity);
    expect(impliedSpeedKmh(DUBAI_MALL, BURJ_AL_ARAB, -5)).toBe(Infinity);
  });
});
