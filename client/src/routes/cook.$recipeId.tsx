import { useEffect, useRef, useState } from 'react'
import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, ArrowRight, Check, Loader2, Minus, Plus, Star, Timer, X } from 'lucide-react'
import { BackLink } from '@/components/BackLink'
import { ErrorState } from '@/components/ErrorState'
import { useWakeLock } from '@/hooks/useWakeLock'
import { apiJson } from '@/lib/api'
import { formatQuantity } from '@/lib/parseItems'
import { useRecipe } from '@/lib/queries'
import { scaleAmount, scaleText } from '@/lib/scale'
import { detectTimers, formatClock } from '@/lib/timers'
import type { RecipeIngredient } from '@/lib/types'
import { cn } from '@/lib/utils'

type CookSearch = {
  /** The list this was opened from, for the way back. */
  list?: string
  /** Undefined: the overview. 0..n-1: a step. n: finished. */
  step?: number
  servings?: number
}

export const Route = createFileRoute('/cook/$recipeId')({
  component: CookPage,
  validateSearch: (s: Record<string, unknown>): CookSearch => ({
    list: typeof s.list === 'string' ? s.list : undefined,
    step: typeof s.step === 'number' && s.step >= 0 ? Math.floor(s.step) : undefined,
    servings: typeof s.servings === 'number' && s.servings > 0 ? s.servings : undefined,
  }),
})

type RunningTimer = { id: number; label: string; total: number; endsAt: number; stepIndex: number }

/** The ingredients a step mentions, matched loosely on their main words. */
function ingredientsForStep(step: string, ingredients: RecipeIngredient[]): RecipeIngredient[] {
  const text = step.toLowerCase()
  return ingredients.filter((ing) =>
    ing.name
      .toLowerCase()
      .split(/[^a-zà-ÿ]+/)
      .filter((w) => w.length > 3)
      .some((w) => text.includes(w.replace(/(es|s)$/, ''))),
  )
}

function beep() {
  try {
    const ctx = new AudioContext()
    for (let i = 0; i < 3; i++) {
      const osc = ctx.createOscillator()
      const gain = ctx.createGain()
      osc.frequency.value = 880
      gain.gain.value = 0.15
      osc.connect(gain).connect(ctx.destination)
      osc.start(ctx.currentTime + i * 0.35)
      osc.stop(ctx.currentTime + i * 0.35 + 0.2)
    }
  } catch {
    // No audio: the vibration and the on-screen "Done" still show.
  }
}

/**
 * Cook: one step at a time, big type, only the ingredients that step uses,
 * timers you start with a tap, and a servings control that scales every
 * amount. Opened from any recipe or any meal on a list, whatever has or
 * hasn't been checked off. Finishing asks "How was it?", which feeds Discover.
 */
function CookPage() {
  const { recipeId } = Route.useParams()
  const search = Route.useSearch()
  const navigate = useNavigate({ from: Route.fullPath })
  const queryClient = useQueryClient()
  const { data: recipe, isLoading, error, refetch } = useRecipe(recipeId)
  const [timers, setTimers] = useState<RunningTimer[]>([])
  const [now, setNow] = useState(() => Date.now())
  const timerId = useRef(0)
  const rung = useRef(new Set<number>())
  useWakeLock()

  useEffect(() => {
    if (timers.length === 0) return
    const t = setInterval(() => setNow(Date.now()), 500)
    return () => clearInterval(t)
  }, [timers.length])

  useEffect(() => {
    for (const t of timers) {
      if (t.endsAt <= now && !rung.current.has(t.id)) {
        rung.current.add(t.id)
        if ('vibrate' in navigator) navigator.vibrate([300, 150, 300])
        beep()
      }
    }
  }, [now, timers])

  // Finishing records the dinner for Chef's memory, and rating it after
  // updates the same meal, so the key is made once per visit.
  const mealKey = useRef(crypto.randomUUID())
  const logged = useRef(false)
  const logMeal = (rating?: number) =>
    apiJson(`/api/meals/${mealKey.current}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ recipe_id: recipeId, rating }),
    }).catch(() => {
      // Memory is a nice-to-have: a meal that fails to log costs nothing here.
    })
  const finished = recipe != null && search.step != null && search.step >= recipe.instructions.length
  useEffect(() => {
    if (finished && !logged.current) {
      logged.current = true
      void logMeal()
    }
  }, [finished])

  const rate = useMutation({
    mutationFn: async (rating: number) => {
      void logMeal(rating)
      return apiJson(`/api/recipes/${recipeId}/rating`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rating }),
      })
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['recipe', recipeId] })
      void queryClient.invalidateQueries({ queryKey: ['recipes'] })
    },
  })

  const exit = search.list
    ? ({ to: '/list/$listId', params: { listId: search.list } } as const)
    : ({ to: '/recipe/$recipeId', params: { recipeId } } as const)

  if (isLoading) {
    return (
      <div className="flex min-h-screen justify-center bg-cream pt-24">
        <Loader2 className="size-6 animate-spin text-ink-muted" />
      </div>
    )
  }
  if (error || !recipe) {
    return (
      <main className="min-h-screen bg-cream px-4 pt-4">
        <ErrorState error={error} onRetry={() => void refetch()} notFoundMessage="This recipe has been deleted." />
      </main>
    )
  }

  const steps = recipe.instructions
  const base = recipe.servings ?? null
  // With a known yield the control counts servings; without one it's a multiplier.
  const servings = search.servings ?? base ?? 1
  const factor = base ? servings / base : servings
  const step = search.step
  const go = (next: Partial<CookSearch>) =>
    void navigate({ search: (prev) => ({ ...prev, ...next }), replace: true })

  const startTimer = (label: string, seconds: number, stepIndex: number) => {
    const id = ++timerId.current
    setNow(Date.now())
    setTimers((ts) => [...ts, { id, label, total: seconds, endsAt: Date.now() + seconds * 1000, stepIndex }])
  }

  const ingredientLine = (ing: RecipeIngredient) =>
    formatQuantity(scaleAmount(ing.amount, factor), ing.unit || null)

  return (
    <main className="flex min-h-screen flex-col bg-cream text-ink">
      <header className="sticky top-0 z-30 border-b border-line bg-cream/95 backdrop-blur safe-area-top">
        <div className="mx-auto flex max-w-3xl items-center gap-2 px-2 py-2">
          <BackLink
            {...exit}
            aria-label="Stop cooking"
            className="flex size-11 shrink-0 items-center justify-center rounded-full text-ink-soft hover:bg-sand"
          >
            <X className="size-6" />
          </BackLink>
          <div className="min-w-0 flex-1">
            <p className="truncate font-semibold">{recipe.title}</p>
            {step != null && step < steps.length && (
              <p className="text-sm text-ink-muted">
                Step {step + 1} of {steps.length}
              </p>
            )}
          </div>
        </div>
        {step != null && step < steps.length && (
          <div className="h-1 bg-line">
            <div className="h-full bg-primary transition-all" style={{ width: `${((step + 1) / steps.length) * 100}%` }} />
          </div>
        )}
        {timers.length > 0 && (
          <ul className="mx-auto flex max-w-3xl flex-wrap gap-2 px-4 py-2">
            {timers.map((t) => {
              const left = Math.ceil((t.endsAt - now) / 1000)
              const done = left <= 0
              return (
                <li
                  key={t.id}
                  role="timer"
                  className={cn(
                    'flex items-center gap-2 rounded-full py-1 pl-3 pr-1 text-sm font-semibold tabular-nums',
                    done ? 'animate-pulse bg-danger text-white' : 'bg-ink text-white',
                  )}
                >
                  <Timer className="size-4" />
                  {done ? `Step ${t.stepIndex + 1}: done` : formatClock(left)}
                  <button
                    type="button"
                    aria-label="Dismiss timer"
                    onClick={() => setTimers((ts) => ts.filter((x) => x.id !== t.id))}
                    className="flex size-8 items-center justify-center rounded-full hover:bg-white/15"
                  >
                    <X className="size-4" />
                  </button>
                </li>
              )
            })}
          </ul>
        )}
      </header>

      <div className="mx-auto w-full max-w-3xl flex-1 px-5 py-6">
        {step == null && (
          <Overview
            servings={servings}
            hasYield={base != null}
            onServings={(n) => go({ servings: n })}
            ingredients={recipe.ingredients}
            line={ingredientLine}
          />
        )}

        {step != null && step < steps.length && (
          <article aria-live="polite">
            <p className="text-2xl leading-relaxed sm:text-3xl">{scaleText(steps[step], factor)}</p>

            {detectTimers(steps[step]).length > 0 && (
              <div className="mt-6 flex flex-wrap gap-2">
                {detectTimers(steps[step]).map((t) => (
                  <button
                    key={t.label}
                    type="button"
                    onClick={() => startTimer(t.label, t.seconds, step)}
                    className="flex min-h-[48px] items-center gap-2 rounded-xl bg-primary px-4 text-base font-semibold shadow-sm"
                  >
                    <Timer className="size-5" />
                    Start {formatClock(t.seconds)} timer
                  </button>
                ))}
              </div>
            )}

            {ingredientsForStep(steps[step], recipe.ingredients).length > 0 && (
              <section className="mt-8 rounded-2xl border border-line bg-white p-4">
                <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-ink-soft">
                  For this step
                </h2>
                <ul className="space-y-1.5 text-lg">
                  {ingredientsForStep(steps[step], recipe.ingredients).map((ing, i) => (
                    <li key={i} className="flex justify-between gap-3">
                      <span>{ing.name}</span>
                      <span className="shrink-0 tabular-nums text-ink-muted">{ingredientLine(ing)}</span>
                    </li>
                  ))}
                </ul>
              </section>
            )}
          </article>
        )}

        {step != null && step >= steps.length && (
          <Finished
            rating={recipe.rating}
            onRate={(r) => rate.mutate(r)}
            rated={rate.isSuccess}
            exit={exit}
          />
        )}
      </div>

      {/* Big, thumb-reachable controls */}
      <footer className="sticky bottom-0 border-t border-line bg-cream/95 px-4 pt-3 pb-[calc(0.75rem+env(safe-area-inset-bottom))] backdrop-blur">
        <div className="mx-auto flex max-w-3xl gap-3">
          {step == null ? (
            <button
              type="button"
              onClick={() => go({ step: 0 })}
              disabled={steps.length === 0}
              className="min-h-[56px] flex-1 rounded-2xl bg-ink text-lg font-semibold text-white"
            >
              Start cooking
            </button>
          ) : step < steps.length ? (
            <>
              <button
                type="button"
                onClick={() => go({ step: step === 0 ? undefined : step - 1 })}
                className="flex min-h-[56px] items-center justify-center gap-2 rounded-2xl border border-line bg-white px-5 text-lg font-medium"
              >
                <ArrowLeft className="size-5" />
                Back
              </button>
              <button
                type="button"
                onClick={() => go({ step: step + 1 })}
                className="flex min-h-[56px] flex-1 items-center justify-center gap-2 rounded-2xl bg-ink text-lg font-semibold text-white"
              >
                {step === steps.length - 1 ? (
                  <>
                    <Check className="size-5" /> Finish
                  </>
                ) : (
                  <>
                    Next <ArrowRight className="size-5" />
                  </>
                )}
              </button>
            </>
          ) : (
            <button
              type="button"
              onClick={() => go({ step: steps.length - 1 })}
              className="flex min-h-[56px] items-center justify-center gap-2 rounded-2xl border border-line bg-white px-5 text-lg font-medium"
            >
              <ArrowLeft className="size-5" />
              Last step
            </button>
          )}
        </div>
      </footer>
    </main>
  )
}

function Overview({
  servings,
  hasYield,
  onServings,
  ingredients,
  line,
}: {
  servings: number
  hasYield: boolean
  onServings: (n: number) => void
  ingredients: RecipeIngredient[]
  line: (ing: RecipeIngredient) => string
}) {
  const step = hasYield ? 1 : 0.5
  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between gap-4 rounded-2xl border border-line bg-white p-4">
        <div>
          <p className="font-semibold">{hasYield ? 'Servings' : 'Amount'}</p>
          <p className="text-sm text-ink-muted">
            {hasYield ? 'Every amount scales to match.' : 'This recipe doesn’t say how many it serves.'}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            aria-label="Fewer"
            disabled={servings <= step}
            onClick={() => onServings(Math.max(step, servings - step))}
            className="flex size-12 items-center justify-center rounded-xl border border-line bg-white disabled:opacity-40"
          >
            <Minus className="size-5" />
          </button>
          <span className="w-12 text-center text-xl font-semibold tabular-nums" aria-live="polite">
            {hasYield ? servings : `×${servings}`}
          </span>
          <button
            type="button"
            aria-label="More"
            onClick={() => onServings(servings + step)}
            className="flex size-12 items-center justify-center rounded-xl border border-line bg-white"
          >
            <Plus className="size-5" />
          </button>
        </div>
      </div>

      <section>
        <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-ink-soft">
          You'll need
        </h2>
        <ul className="divide-y divide-line rounded-2xl border border-line bg-white px-4">
          {ingredients.map((ing, i) => (
            <li key={i} className="flex justify-between gap-3 py-3 text-lg">
              <span>
                {ing.name}
                {ing.note && <span className="text-ink-muted">, {ing.note}</span>}
              </span>
              <span className="shrink-0 tabular-nums text-ink-muted">{line(ing)}</span>
            </li>
          ))}
        </ul>
      </section>
    </div>
  )
}

function Finished({
  rating,
  onRate,
  rated,
  exit,
}: {
  rating: number | null
  onRate: (r: number) => void
  rated: boolean
  exit: { to: '/list/$listId'; params: { listId: string } } | { to: '/recipe/$recipeId'; params: { recipeId: string } }
}) {
  const [picked, setPicked] = useState<number | null>(null)
  const value = picked ?? rating
  return (
    <div className="flex flex-col items-center gap-6 pt-6 text-center">
      <h2 className="text-3xl font-bold">How was it?</h2>
      <div className="flex gap-2" role="radiogroup" aria-label="Rating">
        {[1, 2, 3, 4, 5].map((n) => (
          <button
            key={n}
            type="button"
            role="radio"
            aria-checked={value === n}
            aria-label={`${n} star${n === 1 ? '' : 's'}`}
            onClick={() => {
              setPicked(n)
              onRate(n)
            }}
            className="flex size-14 items-center justify-center rounded-full hover:bg-sand"
          >
            <Star
              className={cn(
                'size-10',
                value != null && n <= value ? 'fill-[#e0a800] text-[#e0a800]' : 'text-ink-faint',
              )}
            />
          </button>
        ))}
      </div>
      <p className="min-h-[1.5rem] text-ink-muted" role="status">
        {rated ? 'Thanks. Discover will suggest more like this, or less.' : 'One tap. It shapes what Discover suggests.'}
      </p>
      <BackLink
        {...exit}
        className="flex min-h-[48px] items-center rounded-xl border border-line bg-white px-5 font-medium hover:bg-sand"
      >
        Done
      </BackLink>
    </div>
  )
}
