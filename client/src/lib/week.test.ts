import { afterEach, describe, expect, it } from 'vitest'
import {
  addDays,
  defaultDay,
  longDate,
  nextOpenDay,
  shortLabel,
  todayISO,
  weekStartFor,
  weekToPlan,
} from './week'
import type { PlanDay } from './types'

const week = (start: string, overrides: Partial<PlanDay>[] = []): PlanDay[] =>
  Array.from({ length: 7 }, (_, i) => ({
    date: addDays(start, i),
    recipe_id: null,
    status: 'open' as const,
    origin: 'user' as const,
    ...overrides[i],
  }))

describe('weekStartFor', () => {
  it('goes back to the most recent shop day, today included', () => {
    // 2026-10-20 is a Tuesday; 5 is Saturday.
    expect(weekStartFor('2026-10-20', 5)).toBe('2026-10-17')
    expect(weekStartFor('2026-10-17', 5)).toBe('2026-10-17')
    expect(weekStartFor('2026-10-16', 5)).toBe('2026-10-10')
    expect(weekStartFor('2026-10-20', 0)).toBe('2026-10-19')
  })

  it('crosses a year end', () => {
    expect(weekStartFor('2027-01-01', 5)).toBe('2026-12-26')
  })
})

describe('todayISO', () => {
  const tz = process.env.TZ
  afterEach(() => {
    if (tz === undefined) delete process.env.TZ
    else process.env.TZ = tz
  })

  it("follows this device's midnight, not UTC's", () => {
    // In London on the night the clocks go back, 00:30 is still 23:30 UTC.
    process.env.TZ = 'Europe/London'
    expect(todayISO(new Date(2026, 9, 24, 23, 59))).toBe('2026-10-24')
    expect(todayISO(new Date(2026, 9, 25, 0, 30))).toBe('2026-10-25')
  })
})

describe('weekToPlan', () => {
  // Weeks start on Saturday (5); 2026-10-17 is a Saturday.
  it('plans the week under way', () => {
    expect(weekToPlan('2026-10-17', 5, [])).toEqual({ weekStart: '2026-10-17', listId: null })
    expect(weekToPlan('2026-10-22', 5, [])).toEqual({ weekStart: '2026-10-17', listId: null })
  })

  it('plans next week on the last day of this one', () => {
    expect(weekToPlan('2026-10-23', 5, [])).toEqual({ weekStart: '2026-10-24', listId: null })
  })

  it('opens the list already made for that week', () => {
    const lists = [
      { id: 'plain', week_start: null },
      { id: 'last', week_start: '2026-10-10' },
      { id: 'this', week_start: '2026-10-17' },
    ]
    expect(weekToPlan('2026-10-20', 5, lists)).toEqual({ weekStart: '2026-10-17', listId: 'this' })
    expect(weekToPlan('2026-10-23', 5, lists).listId).toBeNull()
  })
})

describe('labels', () => {
  it('names the day and month', () => {
    expect(shortLabel('2026-10-17')).toBe('Sat 17 Oct')
    expect(longDate('2026-10-17')).toBe('17 October')
  })
})

describe('defaultDay', () => {
  it('picks today inside the week, else the first evening to plan', () => {
    const days = week('2026-10-17', [{ recipe_id: 'a' }, { status: 'out' }])
    expect(defaultDay(days, '2026-10-20')).toBe('2026-10-20')
    expect(defaultDay(days, '2026-10-10')).toBe('2026-10-19')
    expect(defaultDay([], '2026-10-10')).toBeNull()
  })
})

describe('nextOpenDay', () => {
  it('skips planned and out days and wraps round the week', () => {
    const days = week('2026-10-17', [
      {},
      { recipe_id: 'a' },
      { status: 'out' },
      {},
      { recipe_id: 'b' },
      { recipe_id: 'c' },
      { recipe_id: 'd' },
    ])
    expect(nextOpenDay(days, '2026-10-17')).toBe('2026-10-20')
    expect(nextOpenDay(days, '2026-10-20')).toBe('2026-10-17')
  })

  it('passes over evenings the calendar says are busy', () => {
    const days = week('2026-10-17')
    const busy = new Set(['2026-10-18', '2026-10-19'])
    expect(nextOpenDay(days, '2026-10-17', (d) => busy.has(d))).toBe('2026-10-20')
  })

  it('stays put when every evening is decided', () => {
    const days = week('2026-10-17').map((d) => ({ ...d, recipe_id: 'x' }))
    expect(nextOpenDay(days, '2026-10-19')).toBe('2026-10-19')
  })
})
