/**
 * Narrow it down: a few one-tap questions that end on three finalists.
 *
 * For the evenings when nothing in the top three appeals and you don't know
 * what you want. Each question is the one that best splits the meals still in
 * play, so it rarely takes more than two or three taps, and each answer is
 * sized by how many good meals sit behind it, so the likely answer is the big
 * one. A pure state machine over the day's ranked library: the screen keeps
 * the state, `next()` says what to show. `docs/fixtures/narrow-cases.json`
 * pins the rules for the web and the iOS port.
 */
import { QUICK_MINUTES } from '@/lib/libraryQuery'
import type { Ranked } from '@/lib/fitScore'

export type Question = 'time' | 'mood' | 'base' | 'main'

const QUESTIONS: Question[] = ['time', 'mood', 'base', 'main']

export const PROMPT: Record<Question, string> = {
  time: 'How much time?',
  mood: 'What sort of mood?',
  base: 'What in the middle?',
  main: "What's the main?",
}

const LABEL: Record<string, string> = {
  'time:quick': 'Quick',
  'time:normal': 'Up to an hour',
  'time:slow': 'Happy to take it slow',
  'mood:comforting': 'Comforting',
  'mood:fresh': 'Light and fresh',
  'mood:different': 'Something different',
  'base:rice': 'Rice',
  'base:pasta': 'Pasta',
  'base:potatoes': 'Potatoes',
  'base:bread': 'Bread',
  'base:noodles': 'Noodles',
  'base:none': 'None of those',
  'main:chicken': 'Chicken',
  'main:beef': 'Beef',
  'main:pork': 'Pork',
  'main:lamb': 'Lamb',
  'main:fish': 'Fish',
  'main:veggie': 'Veggie',
  'main:beans': 'Beans and lentils',
}

/** At most this many answers on screen; the smallest fold into Something else. */
const MAX_ANSWERS = 4
/** Stop once this many good meals or fewer are left. */
export const FINALISTS = 3
/** A clashing meal still counts, a little, so its group never vanishes. */
const CLASH_WEIGHT = 0.15

/** One step taken: an answer (one value, or several for Something else), or Don't mind. */
export type Step = {
  question: Question
  values: string[] | null
  preset?: boolean
}

export type NarrowState = { steps: Step[] }

export type Answer = {
  values: string[]
  label: string
  /** Meals behind this answer. */
  count: number
  /** This answer's share of the good meals' weight, 0 to 1, for its size. */
  share: number
}

export type NarrowView =
  | {
      kind: 'question'
      question: Question
      answers: Answer[]
      /** The best meals still in play, and how many there are. */
      peek: Ranked[]
      left: number
    }
  | { kind: 'finalists'; finalists: Ranked[] }

function minutesGroup(m: number | null): string | null {
  if (m == null) return null
  if (m <= QUICK_MINUTES) return 'quick'
  return m <= 60 ? 'normal' : 'slow'
}

/** The meal's answer to a question, or null when it can't say (no tags, no time). */
export function valueOf(r: Ranked, q: Question): string | null {
  if (q === 'time') return minutesGroup(r.recipe.total_minutes)
  return r.recipe.tags?.[q] ?? null
}

function weight(r: Ranked): number {
  return r.fit.clash ? CLASH_WEIGHT : 1 + Math.max(0, r.fit.score) / 20
}

/** A meal that can't answer a question (no tags, no time) leaves the run once it's answered. */
function passes(r: Ranked, steps: Step[]): boolean {
  return steps.every((s) => {
    if (s.values == null) return true
    const v = valueOf(r, s.question)
    return v != null && s.values.includes(v)
  })
}

const pool = (ranked: Ranked[], steps: Step[]) =>
  ranked.filter((r) => passes(r, steps))

/** The answers a question would offer over these meals, biggest first. */
export function answersFor(meals: Ranked[], q: Question): Answer[] {
  const groups = new Map<string, { count: number; weight: number }>()
  let total = 0
  for (const r of meals) {
    const v = valueOf(r, q)
    if (v == null) continue
    const g = groups.get(v) ?? { count: 0, weight: 0 }
    g.count += 1
    g.weight += weight(r)
    total += weight(r)
    groups.set(v, g)
  }
  const sorted = [...groups.entries()].sort(
    (a, b) => b[1].weight - a[1].weight || a[0].localeCompare(b[0]),
  )
  const kept =
    sorted.length > MAX_ANSWERS ? sorted.slice(0, MAX_ANSWERS - 1) : sorted
  const answers: Answer[] = kept.map(([v, g]) => ({
    values: [v],
    label: LABEL[`${q}:${v}`] ?? v,
    count: g.count,
    share: total ? g.weight / total : 0,
  }))
  if (sorted.length > MAX_ANSWERS) {
    const rest = sorted.slice(MAX_ANSWERS - 1)
    const w = rest.reduce((sum, [, g]) => sum + g.weight, 0)
    answers.push({
      values: rest.map(([v]) => v),
      label: 'Something else',
      count: rest.reduce((sum, [, g]) => sum + g.count, 0),
      share: total ? w / total : 0,
    })
  }
  return answers
}

// How evenly a question splits the meals, by weight: the higher, the more one tap tells us.
function entropy(answers: Answer[]): number {
  return answers.reduce(
    (h, a) => (a.share > 0 ? h - a.share * Math.log2(a.share) : h),
    0,
  )
}

/** Three finalists, meals with no clash first, in ranked order. */
function finalists(meals: Ranked[]): Ranked[] {
  return [
    ...meals.filter((r) => !r.fit.clash),
    ...meals.filter((r) => r.fit.clash),
  ].slice(0, FINALISTS)
}

/**
 * Where a run starts. On a quick night the time question is already answered
 * and shown as a chip, unless no quick meal exists.
 */
export function start(ranked: Ranked[], quickNight: boolean): NarrowState {
  const preset: Step = { question: 'time', values: ['quick'], preset: true }
  if (quickNight && ranked.some((r) => valueOf(r, 'time') === 'quick'))
    return { steps: [preset] }
  return { steps: [] }
}

/** The state with any answer that leaves no meal taken back, latest first, so a run never shows nothing. */
export function settle(state: NarrowState, ranked: Ranked[]): NarrowState {
  let steps = state.steps
  while (steps.length > 0 && pool(ranked, steps).length === 0)
    steps = steps.slice(0, -1)
  return steps === state.steps ? state : { steps }
}

export function next(state: NarrowState, ranked: Ranked[]): NarrowView {
  const steps = settle(state, ranked).steps
  const meals = pool(ranked, steps)
  const good = meals.filter((r) => !r.fit.clash).length
  const asked = new Set(steps.map((s) => s.question))
  if (good > FINALISTS) {
    let best: { question: Question; answers: Answer[]; h: number } | null = null
    for (const q of QUESTIONS) {
      if (asked.has(q)) continue
      const answers = answersFor(meals, q)
      if (answers.length < 2) continue
      const h = entropy(answers)
      if (!best || h > best.h) best = { question: q, answers, h }
    }
    if (best) {
      return {
        kind: 'question',
        question: best.question,
        answers: best.answers,
        peek: finalists(meals),
        left: meals.length,
      }
    }
  }
  return { kind: 'finalists', finalists: finalists(meals) }
}

export const answer = (
  state: NarrowState,
  question: Question,
  values: string[],
): NarrowState => ({
  steps: [...state.steps, { question, values }],
})

export const dontMind = (
  state: NarrowState,
  question: Question,
): NarrowState => ({
  steps: [...state.steps, { question, values: null }],
})

export const back = (state: NarrowState): NarrowState => ({
  steps: state.steps.slice(0, -1),
})

/** Labels for the answers so far, for the chips above the question. */
export function answeredLabels(
  state: NarrowState,
): { step: Step; label: string }[] {
  return state.steps
    .filter((s) => s.values != null)
    .map((s) => ({
      step: s,
      label:
        s.values!.length === 1
          ? (LABEL[`${s.question}:${s.values![0]}`] ?? s.values![0])
          : 'Something else',
    }))
}
