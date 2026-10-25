import { useEffect, useState } from 'react'
import { createFileRoute } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Compass, Loader2, RefreshCw, SlidersHorizontal } from 'lucide-react'
import { BottomSheet } from '@/components/BottomSheet'
import { ErrorState } from '@/components/ErrorState'
import { PageHeader } from '@/components/PageHeader'
import { SuggestionCard, SuggestionCardSkeleton } from '@/components/SuggestionCard'
import { Button } from '@/components/ui/button'
import { useUndo } from '@/components/UndoToast'
import { WeekCard } from '@/components/WeekCard'
import { usePullToRefresh } from '@/hooks/usePullToRefresh'
import { useSuggestionActions } from '@/hooks/useSuggestionActions'
import { apiJson } from '@/lib/api'
import { useSuggestions } from '@/lib/queries'
import type { Suggestion } from '@/lib/types'
import { cn } from '@/lib/utils'

export const Route = createFileRoute('/discover')({ component: DiscoverPage })

const SECTION_ORDER = ['For this week', 'Under 30 minutes', 'Something new']

type Prefs = { diet: string; ease: string; notes: string }
const PREFS_KEY = 'omlete:discover-prefs'
const DEFAULT_PREFS: Prefs = { diet: 'any', ease: 'any', notes: '' }

function loadPrefs(): Prefs {
  try {
    return { ...DEFAULT_PREFS, ...JSON.parse(window.localStorage.getItem(PREFS_KEY) ?? '{}') }
  } catch {
    return DEFAULT_PREFS
  }
}

function groupSections(items: Suggestion[]): [string, Suggestion[]][] {
  const groups = new Map<string, Suggestion[]>()
  for (const s of items) {
    const key = s.section && SECTION_ORDER.includes(s.section) ? s.section : 'More ideas'
    if (!groups.has(key)) groups.set(key, [])
    groups.get(key)!.push(s)
  }
  const rank = (k: string) => (SECTION_ORDER.includes(k) ? SECTION_ORDER.indexOf(k) : 99)
  return [...groups.entries()].sort(([a], [b]) => rank(a) - rank(b))
}

/**
 * Explore: new things to cook, so the week doesn't need inventing from
 * scratch. A feed of suggestion cards, each with the reason it's here.
 *
 * Cards come from suggestion records. Today "Get new ideas" fills them from
 * your ratings and lists; later an agent searching the web can fill the same
 * records and this screen won't change. Save, Add to list and Not for me are
 * the taste signals it learns from.
 */
function DiscoverPage() {
  const queryClient = useQueryClient()
  const showUndo = useUndo()
  const { data: suggestions, isLoading, error, refetch } = useSuggestions()
  const { save, addToList, dismiss, clear } = useSuggestionActions()
  const [tuneOpen, setTuneOpen] = useState(false)
  const [prefs, setPrefs] = useState<Prefs>(DEFAULT_PREFS)
  useEffect(() => setPrefs(loadPrefs()), [])

  const refresh = useMutation({
    mutationFn: (p: Prefs) =>
      apiJson<Suggestion[]>('/api/suggestions/refresh', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(p),
      }),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: ['suggestions'] }),
    onError: () => showUndo({ message: "Couldn't get new ideas right now. Try again in a bit." }),
  })

  const getIdeas = () => {
    if (!refresh.isPending) refresh.mutate(prefs)
  }
  const pull = usePullToRefresh(getIdeas)

  const visible = (suggestions ?? []).filter((s) => s.status !== 'dismissed' && s.status !== 'cleared')
  const sections = groupSections(visible)

  return (
    <main className="min-h-screen bg-cream text-ink">
      {pull > 0 && (
        <div className="fixed inset-x-0 top-2 z-40 flex justify-center" aria-hidden>
          <span className="flex size-9 items-center justify-center rounded-full bg-white shadow">
            <RefreshCw className="size-4 text-ink-soft" style={{ transform: `rotate(${pull * 270}deg)`, opacity: pull }} />
          </span>
        </div>
      )}
      <div className="mx-auto max-w-5xl px-4 pt-3 pb-6 sm:px-6 sm:py-10">
        <PageHeader
          title="Discover"
          subtitle="New things to cook, picked for you by Chef."
          actions={
            <div className="flex shrink-0 items-center">
              {visible.length > 0 && (
                <button
                  type="button"
                  onClick={() => clear(visible)}
                  className="min-h-[44px] rounded-full px-2 text-sm font-medium text-ink-soft hover:bg-sand hover:text-ink"
                >
                  Clear all
                </button>
              )}
              <button
                type="button"
                onClick={() => setTuneOpen(true)}
                aria-label="Tune suggestions"
                className="flex size-11 items-center justify-center rounded-full text-ink-soft hover:bg-sand"
              >
                <SlidersHorizontal className="size-5" />
              </button>
              <button
                type="button"
                onClick={getIdeas}
                disabled={refresh.isPending}
                aria-label="Get new ideas"
                className="flex size-11 items-center justify-center rounded-full text-ink-soft hover:bg-sand disabled:opacity-50"
              >
                <RefreshCw className={cn('size-5', refresh.isPending && 'animate-spin')} />
              </button>
            </div>
          }
        />

        <WeekCard offerToPlan />

        {error && <ErrorState error={error} onRetry={() => void refetch()} />}

        {(isLoading || refresh.isPending) && (
          <Shelf title={refresh.isPending ? 'Finding new ideas…' : 'Loading'}>
            {[0, 1, 2].map((i) => (
              <SuggestionCardSkeleton key={i} compact />
            ))}
          </Shelf>
        )}

        {!isLoading && !error && visible.length === 0 && !refresh.isPending && (
          <div className="flex flex-col items-center gap-3 py-16 text-center">
            <Compass className="size-10 text-ink-faint" />
            <p className="font-medium text-ink-soft">No ideas here yet</p>
            <p className="max-w-sm text-sm text-ink-muted">
              Ideas are based on what you rate, save and shop for. The more you cook, the better
              they get.
            </p>
            <Button onClick={getIdeas} className="min-h-[44px] font-semibold">
              Get ideas
            </Button>
          </div>
        )}

        <div className="space-y-8">
          {sections.map(([title, items]) => (
            <Shelf key={title} title={title}>
              {items.map((s) => (
                <SuggestionCard
                  key={s.id}
                  suggestion={s}
                  compact
                  onSave={() => void save(s)}
                  onAddToList={(list) => addToList(s, list)}
                  onDismiss={() => dismiss(s)}
                />
              ))}
            </Shelf>
          ))}
        </div>
      </div>

      <TuneSheet
        open={tuneOpen}
        onOpenChange={setTuneOpen}
        prefs={prefs}
        busy={refresh.isPending}
        onApply={(p) => {
          setPrefs(p)
          try {
            window.localStorage.setItem(PREFS_KEY, JSON.stringify(p))
          } catch {
            // Not remembered next time; still used now.
          }
          setTuneOpen(false)
          refresh.mutate(p)
        }}
      />
    </main>
  )
}

/** A titled shelf: a swipeable row on phones, a grid on wider screens. */
function Shelf({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section aria-label={title}>
      <h2 className="mb-3 text-lg font-semibold">{title}</h2>
      <div className="no-scrollbar -mx-4 flex snap-x snap-mandatory scroll-px-4 gap-3 overflow-x-auto px-4 pb-2 sm:mx-0 sm:grid sm:grid-cols-2 sm:overflow-visible sm:px-0 lg:grid-cols-3 sm:*:w-auto">
        {children}
      </div>
    </section>
  )
}

const DIETS = ['any', 'vegetarian', 'vegan', 'pescatarian', 'meaty']
const EASE = [
  ['any', 'Any'],
  ['quick', 'Quick & easy'],
  ['moderate', 'Moderate'],
  ['involved', 'Involved'],
]

function TuneSheet({
  open,
  onOpenChange,
  prefs,
  onApply,
  busy,
}: {
  open: boolean
  onOpenChange: (o: boolean) => void
  prefs: Prefs
  onApply: (p: Prefs) => void
  busy: boolean
}) {
  const [draft, setDraft] = useState(prefs)
  useEffect(() => setDraft(prefs), [prefs, open])

  const chip = (active: boolean) =>
    cn(
      'min-h-[40px] rounded-full border px-3.5 text-sm capitalize',
      active ? 'border-ink bg-ink text-white' : 'border-line bg-white text-ink-soft hover:bg-sand',
    )

  return (
    <BottomSheet
      open={open}
      onOpenChange={onOpenChange}
      title="Tune suggestions"
      description="Steer the next batch of ideas. Your ratings and lists are always taken into account."
      footer={
        <Button onClick={() => onApply(draft)} disabled={busy} className="min-h-[48px] w-full text-base font-semibold">
          {busy && <Loader2 className="animate-spin" />}
          Get ideas
        </Button>
      }
    >
      <div className="space-y-5">
        <fieldset>
          <legend className="mb-2 text-sm font-medium text-ink-soft">Diet</legend>
          <div className="flex flex-wrap gap-2">
            {DIETS.map((d) => (
              <button key={d} type="button" aria-pressed={draft.diet === d} onClick={() => setDraft({ ...draft, diet: d })} className={chip(draft.diet === d)}>
                {d}
              </button>
            ))}
          </div>
        </fieldset>
        <fieldset>
          <legend className="mb-2 text-sm font-medium text-ink-soft">Effort</legend>
          <div className="flex flex-wrap gap-2">
            {EASE.map(([v, label]) => (
              <button key={v} type="button" aria-pressed={draft.ease === v} onClick={() => setDraft({ ...draft, ease: v })} className={chip(draft.ease === v)}>
                {label}
              </button>
            ))}
          </div>
        </fieldset>
        <label className="block">
          <span className="mb-2 block text-sm font-medium text-ink-soft">Anything else</span>
          <textarea
            value={draft.notes}
            onChange={(e) => setDraft({ ...draft, notes: e.target.value })}
            rows={2}
            placeholder="e.g. use up spinach, kid-friendly, more fish"
            className="w-full resize-none rounded-xl border border-line bg-cream px-3 py-2 text-base outline-none placeholder:text-ink-muted focus:ring-2 focus:ring-ring"
          />
        </label>
      </div>
    </BottomSheet>
  )
}
