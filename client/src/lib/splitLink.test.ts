import { describe, expect, it } from 'vitest'
import { splitLink } from './splitLink'

describe('splitLink', () => {
  it('returns a bare link with no changes', () => {
    expect(
      splitLink('  https://thecheekychickpea.com/vegan-burrito/ '),
    ).toEqual({
      url: 'https://thecheekychickpea.com/vegan-burrito/',
      changes: '',
    })
  })

  it('separates a link from the changes typed after it', () => {
    expect(
      splitLink(
        'https://thecheekychickpea.com/vegan-burrito/\n\n\nBut use quorn mince',
      ),
    ).toEqual({
      url: 'https://thecheekychickpea.com/vegan-burrito/',
      changes: 'But use quorn mince',
    })
  })

  it('finds a link typed after the changes, without trailing punctuation', () => {
    expect(
      splitLink('Make this for 6: https://example.com/recipes/chilli.'),
    ).toEqual({
      url: 'https://example.com/recipes/chilli',
      changes: 'Make this for 6:',
    })
  })

  it('returns null for a description with no link', () => {
    expect(splitLink('something warming with leeks and potatoes')).toBeNull()
  })
})
