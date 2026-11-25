import { config } from './config';
import {
  AttendanceDirection,
  BreakPeriod,
  FlagReason,
  WorkSession,
} from './types';

/**
 * The working-day state machine.
 *
 * Pure — no Firestore, no clock — for the same reason `verification.ts` is:
 * these rules decide how many hours someone is paid for, so they need to be
 * exhaustively testable and impossible to break silently.
 *
 *      none ──in──▶ open ──break_start──▶ on_break
 *                    │  ◀───break_end───────┘
 *                    │                      │
 *                    └────────out───────────┴──▶ closed
 *
 * Checking out directly from a break is allowed and ends the break at the
 * checkout instant. Blocking it would strand anyone who simply left for the
 * day, and the arithmetic stays correct either way.
 */

/** Just enough of a session for the rules to run. */
export interface SessionView {
  checkInAtMs: number;
  status: 'open' | 'on_break';
  breaks: BreakPeriod[];
}

export interface DirectionOutcome {
  /** False when the transition is illegal; the punch is rejected. */
  allowed: boolean;
  rejectReason: FlagReason | null;
  /** Non-blocking observations (late checkout, break overrun, overtime). */
  flags: FlagReason[];
  /** Session state after this punch. */
  nextStatus: 'open' | 'on_break' | 'closed' | 'none';
  /** Populated on checkout. Excludes break time. */
  workedMinutes: number | null;
  /** Accumulated break minutes, on break_end and checkout. */
  breakMinutes: number | null;
  /** True when the punch ends a running break (break_end, or out mid-break). */
  closesBreak: boolean;
}

const MINUTE = 60_000;

const toMinutes = (ms: number): number => Math.max(0, Math.round(ms / MINUTE));

/** Break minutes accumulated so far, counting a running break up to `nowMs`. */
export function accumulatedBreakMinutes(
  breaks: BreakPeriod[],
  nowMs: number,
): number {
  let total = 0;
  for (const period of breaks) {
    const end = period.endAtMs ?? nowMs;
    total += Math.max(0, end - period.startAtMs);
  }
  return toMinutes(total);
}

export function evaluateDirection(input: {
  direction: AttendanceDirection;
  session: SessionView | null;
  nowMs: number;
}): DirectionOutcome {
  const { direction, session, nowMs } = input;

  const reject = (reason: FlagReason): DirectionOutcome => ({
    allowed: false,
    rejectReason: reason,
    flags: [],
    nextStatus: session ? session.status : 'none',
    workedMinutes: null,
    breakMinutes: null,
    closesBreak: false,
  });

  switch (direction) {
    case 'in': {
      // A second check-in without a checkout is either a double-tap or someone
      // trying to restart the clock; both must be refused rather than silently
      // overwriting the original arrival time.
      if (session) return reject(FlagReason.AlreadyCheckedIn);
      return {
        allowed: true,
        rejectReason: null,
        flags: [],
        nextStatus: 'open',
        workedMinutes: null,
        breakMinutes: null,
        closesBreak: false,
      };
    }

    case 'break_start': {
      if (!session) return reject(FlagReason.NoOpenCheckIn);
      if (session.status === 'on_break') return reject(FlagReason.AlreadyOnBreak);
      return {
        allowed: true,
        rejectReason: null,
        flags: [],
        nextStatus: 'on_break',
        workedMinutes: null,
        breakMinutes: accumulatedBreakMinutes(session.breaks, nowMs),
        closesBreak: false,
      };
    }

    case 'break_end': {
      if (!session) return reject(FlagReason.NoOpenCheckIn);
      if (session.status !== 'on_break') return reject(FlagReason.NotOnBreak);

      const breakMinutes = accumulatedBreakMinutes(session.breaks, nowMs);
      const flags: FlagReason[] = [];
      // Flagged, not blocked: an overlong lunch is a conversation with a
      // manager, not something the app should refuse to record.
      if (breakMinutes > config.work.maxBreakMinutes) {
        flags.push(FlagReason.BreakOverrun);
      }
      return {
        allowed: true,
        rejectReason: null,
        flags,
        nextStatus: 'open',
        workedMinutes: null,
        breakMinutes,
        closesBreak: true,
      };
    }

    case 'out': {
      if (!session) return reject(FlagReason.NoOpenCheckIn);

      const breakMinutes = accumulatedBreakMinutes(session.breaks, nowMs);
      const elapsedMinutes = toMinutes(nowMs - session.checkInAtMs);
      const workedMinutes = Math.max(0, elapsedMinutes - breakMinutes);

      const flags: FlagReason[] = [];

      // The real timestamp is always what gets recorded. A forgotten checkout
      // is flagged for a human rather than silently rewritten to a plausible
      // hour — inventing an end time would corrupt the very record this app
      // exists to make trustworthy.
      const expectedEndMs =
        session.checkInAtMs +
        (config.work.standardWorkMinutes + config.work.maxBreakMinutes) * MINUTE;
      if (nowMs > expectedEndMs + config.work.lateCheckoutGraceMinutes * MINUTE) {
        flags.push(FlagReason.LateCheckout);
      }

      if (breakMinutes > config.work.maxBreakMinutes) {
        flags.push(FlagReason.BreakOverrun);
      }
      if (config.work.flagOvertime && workedMinutes > config.work.standardWorkMinutes) {
        flags.push(FlagReason.OvertimeRecorded);
      }

      return {
        allowed: true,
        rejectReason: null,
        flags,
        nextStatus: 'closed',
        workedMinutes,
        breakMinutes,
        closesBreak: session.status === 'on_break',
      };
    }
  }
}

/** What the employee may do next, given the current session. */
export function allowedDirections(
  session: SessionView | null,
): AttendanceDirection[] {
  if (!session) return ['in'];
  return session.status === 'on_break' ? ['break_end', 'out'] : ['break_start', 'out'];
}

/** Applies an allowed punch to the stored session. */
export function applyDirection(input: {
  session: WorkSession;
  direction: AttendanceDirection;
  outcome: DirectionOutcome;
  nowMs: number;
  recordId: string;
}): WorkSession {
  const { session, direction, outcome, nowMs, recordId } = input;
  const breaks = session.breaks.map((b) => ({ ...b }));

  if (direction === 'break_start') {
    breaks.push({ startAtMs: nowMs, endAtMs: null, startRecordId: recordId });
  }
  if (outcome.closesBreak) {
    const running = breaks.find((b) => b.endAtMs === null);
    if (running) {
      running.endAtMs = nowMs;
      running.endRecordId = recordId;
    }
  }

  return {
    ...session,
    breaks,
    status: outcome.nextStatus === 'none' ? session.status : outcome.nextStatus,
    totalBreakMinutes: accumulatedBreakMinutes(breaks, nowMs),
    workedMinutes: outcome.workedMinutes ?? session.workedMinutes,
    checkOutAtMs: direction === 'out' ? nowMs : session.checkOutAtMs,
    checkOutRecordId: direction === 'out' ? recordId : session.checkOutRecordId,
    flags: [...new Set([...session.flags, ...outcome.flags])],
  };
}

const DIRECTION_MESSAGES: Record<AttendanceDirection, string> = {
  in: 'Checked in.',
  out: 'Checked out.',
  break_start: 'Break started.',
  break_end: 'Break ended.',
};

export function directionMessage(
  direction: AttendanceDirection,
  outcome: DirectionOutcome,
): string {
  const base = DIRECTION_MESSAGES[direction];
  if (direction !== 'out' || outcome.workedMinutes === null) return base;

  const h = Math.floor(outcome.workedMinutes / 60);
  const m = outcome.workedMinutes % 60;
  const worked = `${h}h ${m.toString().padStart(2, '0')}m worked`;
  const breaks =
    outcome.breakMinutes && outcome.breakMinutes > 0
      ? `, ${outcome.breakMinutes}m break`
      : '';
  return `${base} ${worked}${breaks}.`;
}
