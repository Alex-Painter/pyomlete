import { describe, expect, it } from 'vitest'
import { formatQuantity, parseItem, parseItems } from './parseItems'

describe('parseItem', () => {
  it('reads a leading count', () => {
    expect(parseItem('2 onions')).toEqual({ amount: 2, unit: null, name: 'onions' })
  })

  it('reads a unit glued to the number', () => {
    expect(parseItem('500g mince')).toEqual({ amount: 500, unit: 'g', name: 'mince' })
  })

  it('reads a spelled-out unit and drops "of"', () => {
    expect(parseItem('2 litres of milk')).toEqual({ amount: 2, unit: 'l', name: 'milk' })
  })

  it('keeps a non-unit word in the name', () => {
    expect(parseItem('2 large onions')).toEqual({
      amount: 2,
      unit: null,
      name: 'large onions',
    })
  })

  it('reads fractions', () => {
    expect(parseItem('½ tsp cumin')).toEqual({ amount: 0.5, unit: 'tsp', name: 'cumin' })
    expect(parseItem('1/2 lemon')).toEqual({ amount: 0.5, unit: null, name: 'lemon' })
  })

  it('reads a trailing count', () => {
    expect(parseItem('eggs x12')).toEqual({ amount: 12, unit: null, name: 'eggs' })
  })

  it('leaves plain names alone', () => {
    expect(parseItem('crème fraîche')).toEqual({
      amount: null,
      unit: null,
      name: 'crème fraîche',
    })
  })

  it('strips bullets from pasted lists', () => {
    expect(parseItem('- bread')?.name).toBe('bread')
    expect(parseItem('• 3 apples')).toEqual({ amount: 3, unit: null, name: 'apples' })
  })
})

describe('parseItems', () => {
  it('splits commas', () => {
    expect(parseItems('milk, eggs, bread').map((i) => i.name)).toEqual([
      'milk',
      'eggs',
      'bread',
    ])
  })

  it('splits a pasted multi-line list and skips blanks', () => {
    expect(parseItems('2 onions\n\n500g mince\n- rice').length).toBe(3)
  })
})

describe('formatQuantity', () => {
  it('glues metric units', () => {
    expect(formatQuantity(500, 'g')).toBe('500g')
    expect(formatQuantity(2, 'tin')).toBe('2 tin')
    expect(formatQuantity(null, 'to taste')).toBe('to taste')
  })
})

describe('formatQuantity display units', () => {
  it('shortens recipe units', () => {
    expect(formatQuantity(400, 'grams')).toBe('400g')
    expect(formatQuantity(1, 'whole')).toBe('1')
  })
})
