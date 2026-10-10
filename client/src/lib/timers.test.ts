import { describe, expect, it } from 'vitest'
import { detectTimers, formatClock } from './timers'

describe('detectTimers', () => {
  it('takes the upper bound of a range', () => {
    expect(detectTimers('Simmer 10–12 mins until thick')).toEqual([
      { label: '10–12 mins', seconds: 720 },
    ])
  })

  it('reads minutes and hours', () => {
    expect(detectTimers('Bake for 45 minutes at 180C')[0].seconds).toBe(2700)
    expect(detectTimers('Roast 1 hr 20 min')[0].seconds).toBe(4800)
  })

  it('reads words', () => {
    expect(detectTimers('rest for a minute')[0].seconds).toBe(60)
  })

  it('finds several', () => {
    expect(detectTimers('Fry 5 mins, then simmer 20 minutes').length).toBe(2)
  })

  it('ignores lengths and temperatures', () => {
    expect(detectTimers('Cut into 2 cm pieces and heat to 180C')).toEqual([])
  })
})

describe('formatClock', () => {
  it('formats', () => {
    expect(formatClock(75)).toBe('1:15')
    expect(formatClock(3700)).toBe('1:01:40')
  })
})
