import { config } from '../config';

/**
 * Local-calendar helpers.
 *
 * "Today" must mean the employee's working day, not UTC — otherwise a WFH
 * exception approved for Tuesday stops working at 04:00 local time in Dubai.
 */

/** `YYYY-MM-DD` in the configured timezone. */
export function dayKey(date: Date, timezone: string = config.timezone): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(date);
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? '';
  return `${get('year')}-${get('month')}-${get('day')}`;
}

/** Hour of day (0-23) in the configured timezone. */
export function localHour(date: Date, timezone: string = config.timezone): number {
  return Number(
    new Intl.DateTimeFormat('en-GB', {
      timeZone: timezone,
      hour: '2-digit',
      hour12: false,
    }).format(date),
  );
}

/** 0 = Sunday. Used to skip weekend presence pings. */
export function localWeekday(date: Date, timezone: string = config.timezone): number {
  const name = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    weekday: 'short',
  }).format(date);
  return ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(name);
}

export const minutes = (n: number): number => n * 60_000;
export const hours = (n: number): number => n * 3_600_000;
export const days = (n: number): number => n * 86_400_000;
