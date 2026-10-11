import { describe, expect, it } from 'vitest'
import { addDays, defaultDay, longDate, nextOpenDay, shortLabel, weekStartFor } from './week'
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

  it('crosses the October clocks change and a year end', () => {
    expect(addDays('2026-10-24', 2)).toBe('2026-10-26')
    expect(weekStartFor('2027-01-01', 5)).toBe('2026-12-26')
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

  it('stays put when every evening is decided', () => {
    const days = week('2026-10-17').map((d) => ({ ...d, recipe_id: 'x' }))
    expect(nextOpenDay(days, '2026-10-19')).toBe('2026-10-19')
  })
})
