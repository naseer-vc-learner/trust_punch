import { describe, expect, it } from 'vitest';
import { AnomalyRecord, detectAnomalies } from '../src/flagAnomalies';
import { FlagReason } from '../src/types';

const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const T0 = 1_700_000_000_000;

function rec(overrides: Partial<AnomalyRecord> & { id: string }): AnomalyRecord {
  return {
    employeeId: 'emp_1',
    deviceId: 'device_a',
    status: 'approved',
    faceMatchScore: 0.9,
    timestampMs: T0,
    dayKey: '2026-08-01',
    location: { latitude: 25.1972, longitude: 55.2744 },
    ...overrides,
  };
}

describe('detectAnomalies — replayed face scores', () => {
  it('flags an identical score seen on three different days', () => {
    const records = [
      rec({ id: 'a', faceMatchScore: 0.8412, dayKey: '2026-08-01', timestampMs: T0 }),
      rec({ id: 'b', faceMatchScore: 0.8412, dayKey: '2026-08-02', timestampMs: T0 + DAY }),
      rec({ id: 'c', faceMatchScore: 0.8412, dayKey: '2026-08-03', timestampMs: T0 + 2 * DAY }),
    ];
    const findings = detectAnomalies(records);
    expect([...findings.keys()].sort()).toEqual(['a', 'b', 'c']);
    expect(findings.get('a')).toContain(FlagReason.ReplayedFaceScore);
  });

  it('does not flag the same score twice on the same day', () => {
    const records = [
      rec({ id: 'a', faceMatchScore: 0.8412, dayKey: '2026-08-01', timestampMs: T0 }),
      rec({ id: 'b', faceMatchScore: 0.8412, dayKey: '2026-08-01', timestampMs: T0 + HOUR }),
    ];
    expect(detectAnomalies(records).size).toBe(0);
  });

  it('does not flag naturally varying scores', () => {
    const records = [
      rec({ id: 'a', faceMatchScore: 0.91, dayKey: '2026-08-01', timestampMs: T0 }),
      rec({ id: 'b', faceMatchScore: 0.87, dayKey: '2026-08-02', timestampMs: T0 + DAY }),
      rec({ id: 'c', faceMatchScore: 0.94, dayKey: '2026-08-03', timestampMs: T0 + 2 * DAY }),
    ];
    expect(detectAnomalies(records).size).toBe(0);
  });

  it('keeps scores from different employees in separate buckets', () => {
    const records = [
      rec({ id: 'a', employeeId: 'emp_1', faceMatchScore: 0.8412, dayKey: '2026-08-01' }),
      rec({ id: 'b', employeeId: 'emp_2', faceMatchScore: 0.8412, dayKey: '2026-08-02', deviceId: 'device_b' }),
      rec({ id: 'c', employeeId: 'emp_3', faceMatchScore: 0.8412, dayKey: '2026-08-03', deviceId: 'device_c' }),
    ];
    expect(detectAnomalies(records).size).toBe(0);
  });
});

describe('detectAnomalies — impossible travel', () => {
  it('flags both ends of a physically impossible hop', () => {
    const records = [
      rec({ id: 'a', timestampMs: T0, location: { latitude: 25.1972, longitude: 55.2744 } }),
      // London, 10 minutes later.
      rec({
        id: 'b',
        timestampMs: T0 + 10 * 60_000,
        dayKey: '2026-08-01',
        location: { latitude: 51.5074, longitude: -0.1278 },
      }),
    ];
    const findings = detectAnomalies(records);
    expect(findings.get('a')).toContain(FlagReason.ImpossibleTravel);
    expect(findings.get('b')).toContain(FlagReason.ImpossibleTravel);
  });

  it('accepts the same hop given enough time for a flight', () => {
    const records = [
      rec({ id: 'a', timestampMs: T0, location: { latitude: 25.1972, longitude: 55.2744 } }),
      rec({
        id: 'b',
        timestampMs: T0 + 8 * HOUR,
        dayKey: '2026-08-01',
        location: { latitude: 51.5074, longitude: -0.1278 },
      }),
    ];
    expect(detectAnomalies(records).size).toBe(0);
  });

  it('skips pairs where either record has no location (WFH)', () => {
    const records = [
      rec({ id: 'a', timestampMs: T0, location: null }),
      rec({
        id: 'b',
        timestampMs: T0 + 60_000,
        location: { latitude: 51.5074, longitude: -0.1278 },
      }),
    ];
    expect(detectAnomalies(records).size).toBe(0);
  });
});

describe('detectAnomalies — device sharing', () => {
  it('flags one device used by two employees', () => {
    const records = [
      rec({ id: 'a', employeeId: 'emp_1', deviceId: 'device_shared', dayKey: '2026-08-01' }),
      rec({
        id: 'b',
        employeeId: 'emp_2',
        deviceId: 'device_shared',
        dayKey: '2026-08-01',
        timestampMs: T0 + HOUR,
      }),
    ];
    const findings = detectAnomalies(records);
    expect(findings.get('a')).toContain(FlagReason.DeviceSharedAcrossEmployees);
    expect(findings.get('b')).toContain(FlagReason.DeviceSharedAcrossEmployees);
  });

  it('leaves one employee on one device alone', () => {
    const records = [
      rec({ id: 'a', dayKey: '2026-08-01' }),
      rec({ id: 'b', dayKey: '2026-08-02', timestampMs: T0 + DAY, faceMatchScore: 0.88 }),
    ];
    expect(detectAnomalies(records).size).toBe(0);
  });
});

describe('detectAnomalies — general', () => {
  it('returns nothing for an empty window', () => {
    expect(detectAnomalies([]).size).toBe(0);
  });

  it('accumulates multiple reasons on one record', () => {
    const records = [
      rec({ id: 'a', employeeId: 'emp_1', deviceId: 'shared', timestampMs: T0 }),
      rec({
        id: 'b',
        employeeId: 'emp_1',
        deviceId: 'shared',
        timestampMs: T0 + 60_000,
        location: { latitude: 51.5074, longitude: -0.1278 },
      }),
      rec({ id: 'c', employeeId: 'emp_2', deviceId: 'shared', timestampMs: T0 + 2 * HOUR }),
    ];
    const findings = detectAnomalies(records);
    expect(findings.get('b')).toEqual(
      expect.arrayContaining([
        FlagReason.ImpossibleTravel,
        FlagReason.DeviceSharedAcrossEmployees,
      ]),
    );
  });
});
