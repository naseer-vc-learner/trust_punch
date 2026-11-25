import { describe, expect, it } from 'vitest';
import { config } from '../src/config';
import {
  accumulatedBreakMinutes,
  allowedDirections,
  applyDirection,
  directionMessage,
  evaluateDirection,
  SessionView,
} from '../src/session';
import { FlagReason, WorkSession } from '../src/types';

const MIN = 60_000;
const HOUR = 60 * MIN;
const NINE_AM = Date.UTC(2026, 7, 6, 9, 0, 0);

function open(overrides: Partial<SessionView> = {}): SessionView {
  return { checkInAtMs: NINE_AM, status: 'open', breaks: [], ...overrides };
}

describe('transitions from "not checked in"', () => {
  it('allows a check-in', () => {
    const r = evaluateDirection({ direction: 'in', session: null, nowMs: NINE_AM });
    expect(r.allowed).toBe(true);
    expect(r.nextStatus).toBe('open');
  });

  it('rejects a checkout with nothing open', () => {
    const r = evaluateDirection({ direction: 'out', session: null, nowMs: NINE_AM });
    expect(r.allowed).toBe(false);
    expect(r.rejectReason).toBe(FlagReason.NoOpenCheckIn);
  });

  it('rejects starting a break before checking in', () => {
    const r = evaluateDirection({ direction: 'break_start', session: null, nowMs: NINE_AM });
    expect(r.rejectReason).toBe(FlagReason.NoOpenCheckIn);
  });

  it('offers only check-in as the next action', () => {
    expect(allowedDirections(null)).toEqual(['in']);
  });
});

describe('transitions while checked in', () => {
  it('rejects a second check-in rather than resetting the arrival time', () => {
    const r = evaluateDirection({ direction: 'in', session: open(), nowMs: NINE_AM + HOUR });
    expect(r.allowed).toBe(false);
    expect(r.rejectReason).toBe(FlagReason.AlreadyCheckedIn);
  });

  it('allows a break to start', () => {
    const r = evaluateDirection({
      direction: 'break_start',
      session: open(),
      nowMs: NINE_AM + 3 * HOUR,
    });
    expect(r.allowed).toBe(true);
    expect(r.nextStatus).toBe('on_break');
  });

  it('rejects ending a break that never started', () => {
    const r = evaluateDirection({ direction: 'break_end', session: open(), nowMs: NINE_AM });
    expect(r.rejectReason).toBe(FlagReason.NotOnBreak);
  });

  it('offers break or checkout as next actions', () => {
    expect(allowedDirections(open())).toEqual(['break_start', 'out']);
  });
});

describe('transitions while on break', () => {
  const onBreak = (startedAgoMs: number, nowMs: number): SessionView => ({
    checkInAtMs: NINE_AM,
    status: 'on_break',
    breaks: [{ startAtMs: nowMs - startedAgoMs, endAtMs: null, startRecordId: 'r1' }],
  });

  it('rejects starting a second break', () => {
    const now = NINE_AM + 4 * HOUR;
    const r = evaluateDirection({
      direction: 'break_start',
      session: onBreak(20 * MIN, now),
      nowMs: now,
    });
    expect(r.rejectReason).toBe(FlagReason.AlreadyOnBreak);
  });

  it('ends a break and reports the accumulated minutes', () => {
    const now = NINE_AM + 4 * HOUR;
    const r = evaluateDirection({
      direction: 'break_end',
      session: onBreak(30 * MIN, now),
      nowMs: now,
    });
    expect(r.allowed).toBe(true);
    expect(r.nextStatus).toBe('open');
    expect(r.breakMinutes).toBe(30);
    expect(r.closesBreak).toBe(true);
    expect(r.flags).toEqual([]);
  });

  it('flags a break past the 1 hour allowance without blocking it', () => {
    const now = NINE_AM + 5 * HOUR;
    const r = evaluateDirection({
      direction: 'break_end',
      session: onBreak(75 * MIN, now),
      nowMs: now,
    });
    expect(r.allowed).toBe(true);
    expect(r.breakMinutes).toBe(75);
    expect(r.flags).toContain(FlagReason.BreakOverrun);
  });

  it('allows checking out mid-break, closing the break at that instant', () => {
    const now = NINE_AM + 9 * HOUR;
    const r = evaluateDirection({
      direction: 'out',
      session: onBreak(15 * MIN, now),
      nowMs: now,
    });
    expect(r.allowed).toBe(true);
    expect(r.closesBreak).toBe(true);
    expect(r.breakMinutes).toBe(15);
    expect(r.workedMinutes).toBe(9 * 60 - 15);
  });
});

describe('checkout arithmetic', () => {
  it('subtracts break time from worked hours', () => {
    const now = NINE_AM + 10 * HOUR; // 9am -> 7pm
    const session = open({
      breaks: [
        { startAtMs: NINE_AM + 3 * HOUR, endAtMs: NINE_AM + 3 * HOUR + 30 * MIN, startRecordId: 'a' },
        { startAtMs: NINE_AM + 6 * HOUR, endAtMs: NINE_AM + 6 * HOUR + 30 * MIN, startRecordId: 'b' },
      ],
    });
    const r = evaluateDirection({ direction: 'out', session, nowMs: now });

    expect(r.breakMinutes).toBe(60);
    expect(r.workedMinutes).toBe(540); // exactly the 9 hour standard day
    expect(r.flags).toEqual([]);
  });

  it('a clean 9 hour day plus 1 hour break raises no flags', () => {
    expect(config.work.standardWorkMinutes).toBe(540);
    expect(config.work.maxBreakMinutes).toBe(60);
  });

  it('flags overtime beyond the standard day', () => {
    const now = NINE_AM + 11 * HOUR;
    const r = evaluateDirection({ direction: 'out', session: open(), nowMs: now });
    expect(r.workedMinutes).toBe(660);
    expect(r.flags).toContain(FlagReason.OvertimeRecorded);
  });

  it('never returns negative worked minutes', () => {
    const now = NINE_AM + 10 * MIN;
    const session = open({
      breaks: [{ startAtMs: NINE_AM, endAtMs: NINE_AM + 30 * MIN, startRecordId: 'a' }],
    });
    const r = evaluateDirection({ direction: 'out', session, nowMs: now });
    expect(r.workedMinutes).toBeGreaterThanOrEqual(0);
  });
});

describe('late checkout — records the real time, flags it', () => {
  it('does not flag a checkout inside the grace window', () => {
    // expected end = 9am + 9h work + 1h break = 7pm; grace is 2h.
    const r = evaluateDirection({
      direction: 'out',
      session: open(),
      nowMs: NINE_AM + 10 * HOUR + 90 * MIN,
    });
    expect(r.flags).not.toContain(FlagReason.LateCheckout);
  });

  it('flags a checkout beyond the grace window', () => {
    const r = evaluateDirection({
      direction: 'out',
      session: open(),
      nowMs: NINE_AM + 10 * HOUR + 3 * HOUR,
    });
    expect(r.allowed).toBe(true);
    expect(r.flags).toContain(FlagReason.LateCheckout);
  });

  it('a forgotten checkout the next morning is allowed and flagged', () => {
    const nextMorning = NINE_AM + 24 * HOUR;
    const r = evaluateDirection({ direction: 'out', session: open(), nowMs: nextMorning });

    expect(r.allowed).toBe(true, );
    expect(r.flags).toContain(FlagReason.LateCheckout);
    // The real elapsed time is reported — never rewritten to a tidy 9 hours.
    expect(r.workedMinutes).toBe(24 * 60);
  });
});

describe('accumulatedBreakMinutes', () => {
  it('counts a running break up to now', () => {
    const now = NINE_AM + 2 * HOUR;
    expect(
      accumulatedBreakMinutes(
        [{ startAtMs: now - 25 * MIN, endAtMs: null, startRecordId: 'a' }],
        now,
      ),
    ).toBe(25);
  });

  it('sums multiple closed breaks', () => {
    expect(
      accumulatedBreakMinutes(
        [
          { startAtMs: NINE_AM, endAtMs: NINE_AM + 20 * MIN, startRecordId: 'a' },
          { startAtMs: NINE_AM + HOUR, endAtMs: NINE_AM + HOUR + 10 * MIN, startRecordId: 'b' },
        ],
        NINE_AM + 5 * HOUR,
      ),
    ).toBe(30);
  });

  it('is zero with no breaks', () => {
    expect(accumulatedBreakMinutes([], NINE_AM)).toBe(0);
  });
});

describe('applyDirection', () => {
  const base: WorkSession = {
    employeeId: 'emp_1',
    dayKey: '2026-08-06',
    checkInAtMs: NINE_AM,
    checkInRecordId: 'rec_in',
    checkOutAtMs: null,
    checkOutRecordId: null,
    breaks: [],
    status: 'open',
    totalBreakMinutes: 0,
    workedMinutes: null,
    flags: [],
  };

  it('opens a break period on break_start', () => {
    const now = NINE_AM + 3 * HOUR;
    const outcome = evaluateDirection({ direction: 'break_start', session: open(), nowMs: now });
    const next = applyDirection({ session: base, direction: 'break_start', outcome, nowMs: now, recordId: 'rec_b' });

    expect(next.status).toBe('on_break');
    expect(next.breaks).toHaveLength(1);
    expect(next.breaks[0].endAtMs).toBeNull();
  });

  it('closes the running break on break_end', () => {
    const start = NINE_AM + 3 * HOUR;
    const end = start + 30 * MIN;
    const withBreak: WorkSession = {
      ...base,
      status: 'on_break',
      breaks: [{ startAtMs: start, endAtMs: null, startRecordId: 'rec_b' }],
    };
    const outcome = evaluateDirection({
      direction: 'break_end',
      session: { checkInAtMs: NINE_AM, status: 'on_break', breaks: withBreak.breaks },
      nowMs: end,
    });
    const next = applyDirection({ session: withBreak, direction: 'break_end', outcome, nowMs: end, recordId: 'rec_e' });

    expect(next.status).toBe('open');
    expect(next.breaks[0].endAtMs).toBe(end);
    expect(next.totalBreakMinutes).toBe(30);
  });

  it('records the checkout and carries flags onto the session', () => {
    const now = NINE_AM + 24 * HOUR;
    const outcome = evaluateDirection({ direction: 'out', session: open(), nowMs: now });
    const next = applyDirection({ session: base, direction: 'out', outcome, nowMs: now, recordId: 'rec_out' });

    expect(next.status).toBe('closed');
    expect(next.checkOutAtMs).toBe(now);
    expect(next.checkOutRecordId).toBe('rec_out');
    expect(next.flags).toContain(FlagReason.LateCheckout);
  });
});

describe('directionMessage', () => {
  it('reports hours and break on checkout', () => {
    const now = NINE_AM + 9 * HOUR + 30 * MIN;
    const session = open({
      breaks: [{ startAtMs: NINE_AM + HOUR, endAtMs: NINE_AM + HOUR + 30 * MIN, startRecordId: 'a' }],
    });
    const outcome = evaluateDirection({ direction: 'out', session, nowMs: now });

    expect(directionMessage('out', outcome)).toBe('Checked out. 9h 00m worked, 30m break.');
  });

  it('is plain for the other directions', () => {
    const outcome = evaluateDirection({ direction: 'in', session: null, nowMs: NINE_AM });
    expect(directionMessage('in', outcome)).toBe('Checked in.');
  });
});
