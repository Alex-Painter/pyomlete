import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { classifyEvening, weekRange } from './calendarDays'
import type { PlanDay } from './types'

const dinner = { start: '18:00', end: '20:30' }
// Local times in London, written as UTC: BST is UTC+1 until the clocks go back on 25 Oct 2026.
const block = (start: string, end: string) => ({ start, end })

describe('classifyEvening', () => {
  const tz = process.env.TZ
  beforeAll(() => {
    process.env.TZ = 'Europe/London'
  })
  afterAll(() => {
    if (tz === undefined) delete process.env.TZ
    else process.env.TZ = tz
  })

  it('is free with nothing on, or something only in the afternoon', () => {
    expect(classifyEvening([], '2026-10-20', dinner)).toEqual({ kind: 'free' })
    expect(
      classifyEvening(
        [block('2026-10-20T13:00:00Z', '2026-10-20T16:00:00Z')],
        '2026-10-20',
        dinner,
      ),
    ).toEqual({ kind: 'free' })
  })

  it('is out when busy across the whole dinner window', () => {
    // 17:30 to 22:00 BST
    expect(
      classifyEvening(
        [block('2026-10-20T16:30:00Z', '2026-10-20T21:00:00Z')],
        '2026-10-20',
        dinner,
      ),
    ).toEqual({ kind: 'out', reason: 'Busy 17:30–22:00' })
  })

  it('is away when busy the whole day', () => {
    expect(
      classifyEvening(
        [block('2026-10-19T23:00:00Z', '2026-10-20T23:00:00Z')],
        '2026-10-20',
        dinner,
      ),
    ).toEqual({ kind: 'away', reason: 'Away all day' })
  })

  it('says when a busy stretch over the window runs into the night', () => {
    expect(
      classifyEvening(
        [block('2026-10-20T13:00:00Z', '2026-10-21T08:00:00Z')],
        '2026-10-20',
        dinner,
      ),
    ).toEqual({ kind: 'out', reason: 'Busy from 14:00' })
  })

  it('is quick when back late or out early', () => {
    // Busy until 19:00 BST
    expect(
      classifyEvening(
        [block('2026-10-20T15:00:00Z', '2026-10-20T18:00:00Z')],
        '2026-10-20',
        dinner,
      ),
    ).toEqual({ kind: 'quick', reason: 'Back at 19:00' })
    // Out at 19:30 BST
    expect(
      classifyEvening(
        [block('2026-10-20T18:30:00Z', '2026-10-20T21:00:00Z')],
        '2026-10-20',
        dinner,
      ),
    ).toEqual({ kind: 'quick', reason: 'Out at 19:30' })
  })

  it('stays free when a short call leaves two hours', () => {
    expect(
      classifyEvening(
        [block('2026-10-20T19:00:00Z', '2026-10-20T19:30:00Z')],
        '2026-10-20',
        dinner,
      ),
    ).toEqual({ kind: 'free' })
  })

  it('reads local time after the clocks go back', () => {
    // 27 Oct is GMT: 18:00 to 19:00 UTC is back at 19:00 local.
    expect(
      classifyEvening(
        [block('2026-10-27T17:00:00Z', '2026-10-27T19:00:00Z')],
        '2026-10-27',
        dinner,
      ),
    ).toEqual({ kind: 'quick', reason: 'Back at 19:00' })
    // Away on the day the clocks change, which is 25 hours long.
    expect(
      classifyEvening(
        [block('2026-10-24T23:00:00Z', '2026-10-26T00:00:00Z')],
        '2026-10-25',
        dinner,
      ),
    ).toEqual({ kind: 'away', reason: 'Away all day' })
  })

  it('spans the week from local midnight to local midnight', () => {
    const days = ['2026-10-24', '2026-10-25', '2026-10-26'].map(
      (date) =>
        ({ date, recipe_id: null, status: 'open' }) as unknown as PlanDay,
    )
    expect(weekRange(days)).toEqual({
      start: '2026-10-23T23:00:00.000Z',
      end: '2026-10-27T00:00:00.000Z',
    })
    expect(weekRange([])).toBeNull()
  })
})
