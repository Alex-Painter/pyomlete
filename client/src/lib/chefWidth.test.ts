// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from 'vitest'
import {
  DEFAULT_CHEF_WIDTH,
  MAX_CHEF_WIDTH,
  MIN_CHEF_WIDTH,
  clampChefWidth,
  saveChefWidth,
  storedChefWidth,
} from './chefWidth'

describe('Chef sidebar width', () => {
  beforeEach(() => localStorage.clear())

  it('keeps a drag within the min and max', () => {
    expect(clampChefWidth(100)).toBe(MIN_CHEF_WIDTH)
    expect(clampChefWidth(5000)).toBe(MAX_CHEF_WIDTH)
    expect(clampChefWidth(450.4)).toBe(450)
    expect(clampChefWidth(NaN)).toBe(DEFAULT_CHEF_WIDTH)
  })

  it('remembers the width for the next visit and shows it', () => {
    expect(storedChefWidth()).toBe(DEFAULT_CHEF_WIDTH)
    saveChefWidth(500)
    expect(storedChefWidth()).toBe(500)
    expect(
      document.documentElement.style.getPropertyValue('--chef-width'),
    ).toBe('500px')
  })

  it('ignores a kept width that is junk or out of range', () => {
    localStorage.setItem('omlete.chef.width', 'wide')
    expect(storedChefWidth()).toBe(DEFAULT_CHEF_WIDTH)
    localStorage.setItem('omlete.chef.width', '9999')
    expect(storedChefWidth()).toBe(MAX_CHEF_WIDTH)
  })
})
