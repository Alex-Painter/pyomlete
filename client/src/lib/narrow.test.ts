import { describe, expect, it } from 'vitest'
import data from '../../../docs/fixtures/narrow-cases.json'
import { answer, back, dontMind, next, settle, start } from './narrow'
import type { NarrowState } from './narrow'
import type { Ranked } from './fitScore'
import type { RecipeSummary, RecipeTags } from './types'

type Meal = (typeof data.library)[number]
type Run = {
  name: string
  quick: boolean
  only?: string[]
  do: string[]
  expect: {
    question?: string
    labels?: string[]
    finalists?: string[]
    preset?: boolean
  }
}

function toRanked(meals: Meal[]): Ranked[] {
  return [...meals]
    .sort(
      (a, b) =>
        Number(a.clash) - Number(b.clash) ||
        b.score - a.score ||
        a.id.localeCompare(b.id),
    )
    .map((m) => {
      const [base, main, mood, cuisine] = (m.tags ?? '').split(' ')
      const tags = m.tags ? ({ base, main, mood, cuisine } as RecipeTags) : null
      return {
        recipe: {
          id: m.id,
          title: m.id,
          total_minutes: m.minutes,
          tags,
        } as RecipeSummary,
        fit: { score: m.score, clash: m.clash, reason: null },
      }
    })
}

function play(run: Run, ranked: Ranked[]): NarrowState {
  let state = start(ranked, run.quick)
  for (const step of run.do) {
    const view = next(state, ranked)
    if (step === 'back') state = back(state)
    else if (view.kind !== 'question')
      throw new Error(`no question for ${step}`)
    else if (step === 'skip') state = dontMind(state, view.question)
    else if (step === 'biggest')
      state = answer(state, view.question, view.answers[0].values)
    else state = answer(state, view.question, [step.replace('answer:', '')])
    state = settle(state, ranked)
  }
  return state
}

describe('Narrow it down cases shared with iOS', () => {
  for (const run of data.runs as Run[]) {
    it(run.name, () => {
      const meals = run.only
        ? data.library.filter((m) => run.only!.includes(m.id))
        : data.library
      const ranked = toRanked(meals)
      const state = play(run, ranked)
      const view = next(state, ranked)
      if (run.expect.question) {
        expect(view.kind).toBe('question')
        if (view.kind !== 'question') return
        expect(view.question).toBe(run.expect.question)
        expect(view.answers.map((a) => a.label)).toEqual(run.expect.labels)
      }
      if (run.expect.finalists) {
        expect(view.kind).toBe('finalists')
        if (view.kind !== 'finalists') return
        expect(view.finalists.map((f) => f.recipe.id)).toEqual(
          run.expect.finalists,
        )
      }
      if (run.expect.preset !== undefined) {
        expect(state.steps.some((s) => s.preset)).toBe(run.expect.preset)
      }
    })
  }
})

describe('Narrow it down rules', () => {
  const ranked = toRanked(data.library)

  it('never asks more than four questions, whatever is answered', () => {
    // Every path through the first two answers, then the biggest after that.
    let first = next(start(ranked, false), ranked)
    if (first.kind !== 'question') throw new Error('expected a question')
    for (const a of first.answers) {
      let state = answer(start(ranked, false), first.question, a.values)
      let asked = 1
      for (;;) {
        const view = next(state, ranked)
        if (view.kind === 'finalists') break
        asked++
        state = answer(state, view.question, view.answers[0].values)
      }
      expect(asked).toBeLessThanOrEqual(4)
    }
    first = next(start(ranked, true), ranked)
    expect(first.kind).toBe('question')
  })

  it('sizes answers by their share, which adds up to the whole', () => {
    const view = next(start(ranked, false), ranked)
    if (view.kind !== 'question') throw new Error('expected a question')
    const total = view.answers.reduce((sum, a) => sum + a.share, 0)
    expect(total).toBeCloseTo(1)
    expect(view.answers.length).toBeLessThanOrEqual(4)
    expect(view.left).toBe(ranked.length)
    expect(view.peek.map((p) => p.recipe.id)).toEqual(
      ranked.slice(0, 3).map((r) => r.recipe.id),
    )
  })

  it('shows a clash as a sliver, never as the biggest answer', () => {
    const pasta = next(
      { steps: [{ question: 'main', values: ['veggie'] }] },
      ranked,
    )
    if (pasta.kind !== 'question') throw new Error('expected a question')
    const sliver = pasta.answers.find((a) => a.label === 'Pasta')
    expect(sliver && sliver.share).toBeLessThan(0.1)
  })
})
