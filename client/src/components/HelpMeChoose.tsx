import { useEffect, useRef, useState } from 'react'
import { ArrowLeft, X } from 'lucide-react'
import { MealPickCard } from '@/components/MealPickCard'
import type { RowMark } from '@/components/DayLibrary'
import {
  PROMPT,
  answer,
  answeredLabels,
  back,
  dontMind,
  next,
  settle,
  start,
} from '@/lib/narrow'
import type { NarrowState } from '@/lib/narrow'
import type { Ranked } from '@/lib/fitScore'
import type { RecipeSummary } from '@/lib/types'

/** The space the answers share; each gets its share of it, never under a tappable 56px. */
const ANSWERS_HEIGHT = 240
const MIN_ANSWER = 56

/**
 * Narrow it down, inline where the top three were: one question at a time,
 * answered with one tap on a button sized by how many good meals sit behind
 * it, until three finalists are left. Back and Don't mind are always there,
 * and the peek row shows where it's heading; tapping a meal there ends the run.
 */
export function HelpMeChoose({
  ranked,
  quickNight,
  markFor,
  onPick,
  onClose,
}: {
  ranked: Ranked[]
  quickNight: boolean
  markFor: (r: RecipeSummary) => RowMark
  onPick: (r: RecipeSummary) => void
  onClose: () => void
}) {
  const [state, setState] = useState<NarrowState>(() =>
    start(ranked, quickNight),
  )
  const view = next(state, ranked)
  const heading = useRef<HTMLHeadingElement>(null)
  const steps = state.steps.length
  const firstRender = useRef(true)

  // Move focus to each new question, so a keyboard or screen reader follows the run.
  useEffect(() => {
    if (firstRender.current) {
      firstRender.current = false
      return
    }
    heading.current?.focus()
  }, [steps])

  const go = (s: NarrowState) => setState(settle(s, ranked))
  const chips = answeredLabels(state)

  return (
    <section
      aria-label="Help me choose"
      className="mb-4 rounded-2xl border border-line bg-white p-3 shadow-sm"
    >
      <div className="mb-2 flex items-center justify-between gap-2">
        <div className="flex min-w-0 flex-wrap items-center gap-1.5">
          <span className="px-1 text-sm font-semibold text-ink-muted">
            Help me choose
          </span>
          {chips.map(({ step, label }) => (
            <span
              key={step.question}
              className="rounded-full bg-sand px-3 py-1 text-sm font-medium text-ink-soft"
            >
              {step.preset ? 'Quick night' : label}
            </span>
          ))}
        </div>
        <button
          type="button"
          onClick={onClose}
          aria-label="Stop choosing"
          className="flex size-11 shrink-0 items-center justify-center rounded-full text-ink-muted hover:bg-sand"
        >
          <X className="size-5" />
        </button>
      </div>

      {view.kind === 'question' ? (
        <>
          <h3
            ref={heading}
            tabIndex={-1}
            className="mb-2 px-1 text-lg font-semibold outline-none"
          >
            {PROMPT[view.question]}
          </h3>
          <div className="flex flex-col gap-2">
            {view.answers.map((a) => (
              <button
                key={a.values.join(',')}
                type="button"
                onClick={() => go(answer(state, view.question, a.values))}
                style={{
                  height: Math.max(MIN_ANSWER, a.share * ANSWERS_HEIGHT),
                }}
                className="flex w-full items-center justify-between gap-3 rounded-xl bg-cream px-4 text-left font-semibold hover:bg-sand motion-safe:transition-[height] motion-safe:duration-200"
              >
                <span>{a.label}</span>
                <span className="text-sm font-normal text-ink-muted">
                  {a.count === 1 ? '1 meal' : `${a.count} meals`}
                </span>
              </button>
            ))}
          </div>
          <div className="mt-2 flex gap-2">
            <button
              type="button"
              onClick={() => go(back(state))}
              disabled={steps === 0}
              className="flex min-h-[44px] items-center gap-1.5 rounded-xl px-3 text-sm font-semibold text-ink-soft hover:bg-sand disabled:opacity-40"
            >
              <ArrowLeft className="size-4" />
              Back
            </button>
            <button
              type="button"
              onClick={() => go(dontMind(state, view.question))}
              className="min-h-[44px] rounded-xl px-3 text-sm font-semibold text-ink-soft hover:bg-sand"
            >
              Don't mind
            </button>
          </div>
          <div className="mt-3 border-t border-line pt-3">
            <p className="mb-2 px-1 text-sm text-ink-muted">
              Leading now, {view.left === 1 ? '1 meal' : `${view.left} meals`}{' '}
              left
            </p>
            <div className="no-scrollbar -mx-3 flex gap-2 overflow-x-auto px-3">
              {view.peek.map(({ recipe }) => (
                <button
                  key={recipe.id}
                  type="button"
                  onClick={() => onPick(recipe)}
                  className="min-h-[44px] shrink-0 rounded-full border border-line px-4 text-sm font-medium hover:bg-sand"
                >
                  {recipe.title}
                </button>
              ))}
            </div>
          </div>
        </>
      ) : (
        <>
          <h3
            ref={heading}
            tabIndex={-1}
            className="mb-2 px-1 text-lg font-semibold outline-none"
          >
            {view.finalists.length === 1
              ? 'Your finalist'
              : `Your ${view.finalists.length} finalists`}
          </h3>
          <ul className="space-y-2">
            {view.finalists.map(({ recipe, fit }) => (
              <MealPickCard
                key={recipe.id}
                recipe={recipe}
                fit={fit}
                mark={markFor(recipe)}
                onPick={() => onPick(recipe)}
              />
            ))}
          </ul>
          <div className="mt-2 flex gap-2">
            <button
              type="button"
              onClick={() => go(back(state))}
              disabled={steps === 0}
              className="flex min-h-[44px] items-center gap-1.5 rounded-xl px-3 text-sm font-semibold text-ink-soft hover:bg-sand disabled:opacity-40"
            >
              <ArrowLeft className="size-4" />
              Back
            </button>
            <button
              type="button"
              onClick={() => go(start(ranked, quickNight))}
              className="min-h-[44px] rounded-xl px-3 text-sm font-semibold text-ink-soft hover:bg-sand"
            >
              Start over
            </button>
          </div>
        </>
      )}
    </section>
  )
}
