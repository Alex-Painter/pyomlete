import { Link } from '@tanstack/react-router'
import {
  AlertCircle,
  Bookmark,
  BookmarkCheck,
  Clock,
  ExternalLink,
  Loader2,
  Sparkles,
  ThumbsDown,
} from 'lucide-react'
import { AddToListButton } from '@/components/AddToListButton'
import { RecipeThumb } from '@/components/RecipeThumb'
import { formatMinutes } from '@/components/RecipeMetaRow'
import type { Suggestion } from '@/lib/types'
import { cn } from '@/lib/utils'

/**
 * A Discover card: photo, title, time, source and the one-line reason it was
 * suggested, with Save, Add to list and Not for me.
 *
 * Built on a suggestion record rather than a recipe, so whatever fills the
 * feed (the suggest endpoint now, an agent later) needs no UI change. Mirrors
 * a SwiftUI view: `suggestion`, `onSave`, `onAddToList(list)`, `onDismiss`.
 */
export function SuggestionCard({
  suggestion: s,
  onSave,
  onAddToList,
  onDismiss,
  compact = false,
}: {
  suggestion: Suggestion
  onSave: () => void
  onAddToList: (list: { id: string; name: string }) => Promise<void> | void
  onDismiss: () => void
  compact?: boolean
}) {
  const saving = s.status === 'saving'
  const saved = s.status === 'saved'
  const failed = s.status === 'failed'

  return (
    <article
      className={cn(
        'flex flex-col overflow-hidden rounded-2xl border border-line bg-white shadow-sm',
        compact && 'w-64 shrink-0 snap-start',
      )}
    >
      <RecipeThumb src={s.image_url} title={s.title} className="aspect-[4/3] w-full" />

      <div className="flex flex-1 flex-col gap-2 p-4">
        <h3 className="text-base font-semibold leading-snug">
          {saved && s.recipe_id ? (
            <Link
              to="/recipe/$recipeId"
              params={{ recipeId: s.recipe_id }}
              className="hover:underline underline-offset-4"
            >
              {s.title}
            </Link>
          ) : (
            s.title
          )}
        </h3>

        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-ink-muted">
          {s.total_minutes != null && (
            <span className="flex items-center gap-1">
              <Clock className="size-3.5" />
              {formatMinutes(s.total_minutes)}
            </span>
          )}
          {s.source_url ? (
            <a
              href={s.source_url}
              target="_blank"
              rel="noreferrer noopener"
              className="flex min-w-0 items-center gap-1 underline underline-offset-4 hover:text-ink"
            >
              <ExternalLink className="size-3.5 shrink-0" />
              <span className="truncate">{s.source_name || 'Source'}</span>
            </a>
          ) : (
            s.source_name && <span>{s.source_name}</span>
          )}
        </div>

        {s.reason && (
          <p className="flex items-start gap-1.5 text-sm text-[#7a5a12]">
            <Sparkles className="mt-0.5 size-3.5 shrink-0" />
            <span>{s.reason}</span>
          </p>
        )}
        {!compact && s.description && <p className="text-sm text-ink-soft">{s.description}</p>}

        <div className="flex-1" />

        {saving && (
          <p className="flex items-center gap-2 text-sm text-ink-muted" role="status">
            <Loader2 className="size-4 animate-spin" />
            Saving. The full recipe fills in shortly.
          </p>
        )}
        {failed && (
          <p className="flex items-center gap-2 text-sm text-danger" role="status">
            <AlertCircle className="size-4" />
            Couldn't save this one.
          </p>
        )}

        <div className="flex items-center gap-2 pt-1">
          {saved && s.recipe_id ? (
            <Link
              to="/recipe/$recipeId"
              params={{ recipeId: s.recipe_id }}
              className="flex min-h-[40px] items-center gap-1.5 rounded-lg border border-line px-3 text-sm font-medium text-ink-soft hover:bg-sand"
            >
              <BookmarkCheck className="size-4 text-success" />
              Saved
            </Link>
          ) : (
            <button
              type="button"
              onClick={onSave}
              disabled={saving}
              className="flex min-h-[40px] items-center gap-1.5 rounded-lg border border-line px-3 text-sm font-medium text-ink-soft hover:bg-sand disabled:opacity-50"
            >
              <Bookmark className="size-4" />
              {failed ? 'Try again' : 'Save'}
            </button>
          )}
          <AddToListButton
            size="sm"
            onAdd={onAddToList}
            disabled={saving}
            className="min-w-0 flex-1"
          />
        </div>
        <button
          type="button"
          onClick={onDismiss}
          aria-label={`Not for me: ${s.title}`}
          className="-mb-1 flex min-h-[40px] items-center justify-center gap-1.5 self-start rounded-lg px-2 text-sm text-ink-muted hover:bg-sand hover:text-ink"
        >
          <ThumbsDown className="size-4" />
          Not for me
        </button>
      </div>
    </article>
  )
}

export function SuggestionCardSkeleton({ compact = false }: { compact?: boolean }) {
  return (
    <div
      aria-hidden
      className={cn(
        'overflow-hidden rounded-2xl border border-line bg-white',
        compact && 'w-64 shrink-0',
      )}
    >
      <div className="aspect-[4/3] w-full animate-pulse bg-mist" />
      <div className="space-y-2 p-4">
        <div className="h-4 w-3/4 animate-pulse rounded bg-mist" />
        <div className="h-3 w-1/3 animate-pulse rounded bg-mist" />
        <div className="h-3 w-2/3 animate-pulse rounded bg-mist" />
        <div className="mt-3 h-10 w-full animate-pulse rounded-lg bg-mist" />
      </div>
    </div>
  )
}
