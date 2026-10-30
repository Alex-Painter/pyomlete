/**
 * What the calendar says about each evening.
 *
 * The calendar only suggests: this reads busy blocks and says what they mean
 * for dinner, and nothing here writes to a list. A busy evening is shown on
 * the week and leaves the day alone; Out and Quick night stay the person's own
 * taps. Times are local, so a week across the clocks changing still lines up.
 */
import type { ISODate, PlanDay } from '@/lib/types'

export type BusyBlock = { start: string; end: string }

/** When dinner happens, as "HH:MM" local times. */
export type DinnerWindow = { start: string; end: string }

export type Evening =
  | { kind: 'free' }
  /** Busy the whole day: likely away. */
  | { kind: 'away'; reason: string }
  /** Busy across the whole dinner window. */
  | { kind: 'out'; reason: string }
  /** Busy for part of it: a quick dinner fits. */
  | { kind: 'quick'; reason: string }

/** With this much free time in the window, the evening counts as free. */
export const ENOUGH_MINUTES = 120

function localDate(date: ISODate, plusDays = 0, time = '00:00'): Date {
  const [y, m, d] = date.split('-').map(Number)
  const [hh, mm] = time.split(':').map(Number)
  return new Date(y, m - 1, d + plusDays, hh, mm)
}

const pad = (n: number) => String(n).padStart(2, '0')
/** "19:30", local. */
const clock = {
  format(ms: number) {
    const d = new Date(ms)
    return `${pad(d.getHours())}:${pad(d.getMinutes())}`
  },
}

/** The week's span, local midnight to local midnight, for `/api/calendar/busy`. */
export function weekRange(
  days: PlanDay[],
): { start: string; end: string } | null {
  if (days.length === 0) return null
  return {
    start: localDate(days[0].date).toISOString(),
    end: localDate(days[days.length - 1].date, 1).toISOString(),
  }
}

export function classifyEvening(
  busy: BusyBlock[],
  date: ISODate,
  dinner: DinnerWindow,
): Evening {
  const dayStart = localDate(date).getTime()
  const dayEnd = localDate(date, 1).getTime()
  const from = localDate(date, 0, dinner.start).getTime()
  const to = localDate(date, 0, dinner.end).getTime()
  const blocks = busy
    .map((b) => ({ start: Date.parse(b.start), end: Date.parse(b.end) }))
    .filter((b) => b.end > from && b.start < to)
    .sort((a, b) => a.start - b.start)
  if (blocks.length === 0) return { kind: 'free' }

  if (blocks.some((b) => b.start <= dayStart && b.end >= dayEnd))
    return { kind: 'away', reason: 'Away all day' }
  const whole = blocks.find((b) => b.start <= from && b.end >= to)
  if (whole) {
    const s = Math.max(whole.start, dayStart)
    const e = Math.min(whole.end, dayEnd)
    return {
      kind: 'out',
      reason:
        s === dayStart || e === dayEnd
          ? `Busy ${s === dayStart ? 'until' : 'from'} ${clock.format(s === dayStart ? e : s)}`
          : `Busy ${clock.format(s)}–${clock.format(e)}`,
    }
  }

  // The longest stretch of the window with nothing on.
  let longest = 0
  let cursor = from
  for (const b of blocks) {
    longest = Math.max(longest, b.start - cursor)
    cursor = Math.max(cursor, b.end)
  }
  longest = Math.max(longest, to - cursor)
  if (longest >= ENOUGH_MINUTES * 60_000) return { kind: 'free' }

  const first = blocks[0]
  return {
    kind: 'quick',
    reason:
      first.start <= from
        ? `Back at ${clock.format(first.end)}`
        : `Out at ${clock.format(first.start)}`,
  }
}

/** Each day's evening, by date. */
export function classifyWeek(
  busy: BusyBlock[],
  days: PlanDay[],
  dinner: DinnerWindow,
): Map<ISODate, Evening> {
  return new Map(
    days.map((d) => [d.date, classifyEvening(busy, d.date, dinner)]),
  )
}

/** An evening the calendar says has no dinner at home. */
export const isBusyEvening = (
  e: Evening | undefined,
): e is Extract<Evening, { kind: 'out' | 'away' }> =>
  e?.kind === 'out' || e?.kind === 'away'
