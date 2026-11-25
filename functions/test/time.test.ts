import { describe, expect, it } from 'vitest';
import { dayKey, localHour, localWeekday } from '../src/lib/time';
import { pickDistinctMinutes, startOfLocalHour } from '../src/wfh';

describe('dayKey', () => {
  it('uses the local calendar day, not UTC', () => {
    // 22:30 UTC on the 1st is already 02:30 on the 2nd in Dubai (UTC+4).
    const instant = new Date('2026-08-01T22:30:00Z');
    expect(dayKey(instant, 'UTC')).toBe('2026-08-01');
    expect(dayKey(instant, 'Asia/Dubai')).toBe('2026-08-02');
  });

  it('handles a zone behind UTC', () => {
    const instant = new Date('2026-08-02T02:00:00Z');
    expect(dayKey(instant, 'America/New_York')).toBe('2026-08-01');
  });
});

describe('localHour', () => {
  it('converts into the target zone', () => {
    const instant = new Date('2026-08-01T10:00:00Z');
    expect(localHour(instant, 'UTC')).toBe(10);
    expect(localHour(instant, 'Asia/Dubai')).toBe(14);
  });

  it('renders local midnight as 0, not 24', () => {
    expect(localHour(new Date('2026-08-01T20:00:00Z'), 'Asia/Dubai')).toBe(0);
  });
});

describe('localWeekday', () => {
  it('returns 0 for Sunday', () => {
    expect(localWeekday(new Date('2026-08-02T09:00:00Z'), 'UTC')).toBe(0);
  });
  it('returns 6 for Saturday', () => {
    expect(localWeekday(new Date('2026-08-01T09:00:00Z'), 'UTC')).toBe(6);
  });
});

describe('startOfLocalHour', () => {
  it('resolves 09:00 local to the right UTC instant', () => {
    const ref = new Date('2026-08-01T12:00:00Z'); // 16:00 Dubai
    const nine = startOfLocalHour(ref, 9, 'Asia/Dubai');
    expect(new Date(nine).toISOString()).toBe('2026-08-01T05:00:00.000Z');
  });

  it('stays correct in a DST zone during summer time', () => {
    const ref = new Date('2026-08-01T12:00:00Z');
    const nine = startOfLocalHour(ref, 9, 'Europe/London'); // BST = UTC+1
    expect(new Date(nine).toISOString()).toBe('2026-08-01T08:00:00.000Z');
  });

  it('stays correct in the same zone during winter time', () => {
    const ref = new Date('2026-01-15T12:00:00Z');
    const nine = startOfLocalHour(ref, 9, 'Europe/London'); // GMT = UTC
    expect(new Date(nine).toISOString()).toBe('2026-01-15T09:00:00.000Z');
  });
});

describe('pickDistinctMinutes', () => {
  it('returns the requested count, distinct and sorted', () => {
    const picks = pickDistinctMinutes(4, 480);
    expect(picks).toHaveLength(4);
    expect(new Set(picks).size).toBe(4);
    expect([...picks].sort((a, b) => a - b)).toEqual(picks);
    picks.forEach((p) => {
      expect(p).toBeGreaterThanOrEqual(0);
      expect(p).toBeLessThan(480);
    });
  });

  it('does not hang when asked for more slots than the span allows', () => {
    expect(pickDistinctMinutes(10, 3)).toHaveLength(3);
  });
});
