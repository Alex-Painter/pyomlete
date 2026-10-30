/**
 * Calendar dates for the week view. Dates are `YYYY-MM-DD` strings, as the
 * API sends them, and all arithmetic runs in UTC so a clocks change can never
 * make a day 23 hours long and skip a date.
 */
import type { ISODate, PlanDay } from '@/lib/types'

const DAY_SHORT = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
const DAY_LONG = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']
const MONTH_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const MONTH_LONG = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
]

const MS_PER_DAY = 86_400_000

function toUTC(date: ISODate): Date {
  const [y, m, d] = date.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d))
}

function fromUTC(d: Date): ISODate {
  return d.toISOString().slice(0, 10)
}

/** Today on this device's calendar, not UTC's. */
export function todayISO(now: Date = new Date()): ISODate {
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

export function addDays(date: ISODate, n: number): ISODate {
  return fromUTC(new Date(toUTC(date).getTime() + n * MS_PER_DAY))
}

/** Whole days from `a` to `b`; negative when `b` is earlier. */
export function daysBetween(a: ISODate, b: ISODate): number {
  return Math.round((toUTC(b).getTime() - toUTC(a).getTime()) / MS_PER_DAY)
}

/** 0 is Monday, matching the server's `week_start_weekday`. */
export function weekdayOf(date: ISODate): number {
  return (toUTC(date).getUTCDay() + 6) % 7
}

/** The most recent `weekday` on or before `today`. */
export function weekStartFor(today: ISODate, weekday: number): ISODate {
  return addDays(today, -((weekdayOf(today) - weekday + 7) % 7))
}

/**
 * The week "Plan a week" opens: this one, or next week on its last day, when
 * this week is all but over. An existing list for that week is opened rather
 * than a second one made.
 */
export function weekToPlan(
  today: ISODate,
  weekday: number,
  lists: { id: string; week_start: ISODate | null }[],
): { weekStart: ISODate; listId: string | null } {
  const current = weekStartFor(today, weekday)
  const weekStart = daysBetween(current, today) === 6 ? addDays(current, 7) : current
  return { weekStart, listId: lists.find((l) => l.week_start === weekStart)?.id ?? null }
}

export const dayShort = (date: ISODate) => DAY_SHORT[weekdayOf(date)]
export const dayLong = (date: ISODate) => DAY_LONG[weekdayOf(date)]
export const dayOfMonth = (date: ISODate) => toUTC(date).getUTCDate()

/** "Tue 20 Oct" */
export function shortLabel(date: ISODate): string {
  return `${dayShort(date)} ${dayOfMonth(date)} ${MONTH_SHORT[toUTC(date).getUTCMonth()]}`
}

/** "20 October" */
export function longDate(date: ISODate): string {
  return `${dayOfMonth(date)} ${MONTH_LONG[toUTC(date).getUTCMonth()]}`
}

/**
 * What an evening shows. A meal wins over Out: putting a meal on an out day
 * plans it, as the server does.
 */
export type DayKind = 'planned' | 'open' | 'out'

export function dayKind(day: PlanDay): DayKind {
  if (day.recipe_id != null) return 'planned'
  return day.status === 'out' ? 'out' : 'open'
}

export const isOpenEmpty = (day: PlanDay) => dayKind(day) === 'open'

/** Today when it's in the week, else the first evening still to plan. */
export function defaultDay(days: PlanDay[], today: ISODate): ISODate | null {
  if (days.length === 0) return null
  if (days.some((d) => d.date === today)) return today
  return (days.find(isOpenEmpty) ?? days[0]).date
}

/**
 * The next evening still to plan after `from`, wrapping round the week, so
 * filling a week is one tap per day. Stays on `from` when nothing is left.
 * `skip` passes over evenings the calendar says you're out.
 */
export function nextOpenDay(
  days: PlanDay[],
  from: ISODate,
  skip: (date: ISODate) => boolean = () => false,
): ISODate {
  const i = days.findIndex((d) => d.date === from)
  for (let step = 1; step < days.length; step++) {
    const day = days[(i + step) % days.length]
    if (isOpenEmpty(day) && !skip(day.date)) return day.date
  }
  return from
}

/** "August" */
export const monthLong = (date: ISODate) => MONTH_LONG[toUTC(date).getUTCMonth()]
