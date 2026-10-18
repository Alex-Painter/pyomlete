import { describe, expect, it } from 'vitest'
import { areaAboveKeyboard } from './keyboard'

describe('areaAboveKeyboard', () => {
  it('is null with no keyboard', () => {
    expect(
      areaAboveKeyboard(800, { height: 800, offsetTop: 0, scale: 1 }),
    ).toBeNull()
  })

  it('ignores a toolbar collapsing', () => {
    expect(
      areaAboveKeyboard(800, { height: 740, offsetTop: 0, scale: 1 }),
    ).toBeNull()
  })

  it('ignores pinch zoom', () => {
    expect(
      areaAboveKeyboard(800, { height: 400, offsetTop: 120, scale: 2 }),
    ).toBeNull()
  })

  it('gives the visible area above a keyboard', () => {
    expect(
      areaAboveKeyboard(844, { height: 508, offsetTop: 30, scale: 1 }),
    ).toEqual({ top: 30, height: 508 })
  })
})
