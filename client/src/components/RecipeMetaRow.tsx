import { Clock, ExternalLink, Users } from 'lucide-react'
import { cn } from '@/lib/utils'

/** Provenance and timings — only ever populated by a URL import. */
export type RecipeMetadata = {
  servings?: number | null
  prep_minutes?: number | null
  cook_minutes?: number | null
  total_minutes?: number | null
  image_url?: string | null
  source_url?: string | null
  source_name?: string | null
  description?: string | null
  cuisine?: string | null
}

export function formatMinutes(minutes: number): string {
  if (minutes < 60) return `${minutes} min`
  const hours = Math.floor(minutes / 60)
  const rest = minutes % 60
  return rest === 0 ? `${hours} hr` : `${hours} hr ${rest} min`
}

/**
 * Time, servings and attribution for an imported recipe.
 *
 * Renders nothing at all when none of it is set, which is the case for every
 * recipe created by hand or from photos — the row should not leave a gap in
 * layouts it has nothing to say in.
 */
export function RecipeMetaRow({ recipe }: { recipe: RecipeMetadata }) {
  const time = recipe.total_minutes ?? recipe.cook_minutes
  const hasAnything = time != null || recipe.servings != null || recipe.source_url

  if (!hasAnything) return null

  return (
    <div className="flex flex-wrap items-center gap-x-4 gap-y-1.5 text-sm text-ink-muted">
      {time != null && (
        <span className="flex items-center gap-1.5">
          <Clock className="size-3.5 shrink-0" />
          {formatMinutes(time)}
        </span>
      )}

      {recipe.servings != null && (
        <span className="flex items-center gap-1.5">
          <Users className="size-3.5 shrink-0" />
          Serves {recipe.servings}
        </span>
      )}

      {recipe.source_url && (
        <a
          href={recipe.source_url}
          target="_blank"
          rel="noreferrer noopener"
          className="flex items-center gap-1.5 hover:text-ink-soft underline underline-offset-4 transition-colors min-w-0"
        >
          <ExternalLink className="size-3.5 shrink-0" />
          <span className="truncate">{recipe.source_name || 'Source'}</span>
        </a>
      )}
    </div>
  )
}

/**
 * The hero image from the source page.
 *
 * We store the origin's URL rather than re-hosting, so this can rot. It hides
 * itself on error instead of leaving a broken-image icon in the layout.
 */
export function RecipeHeroImage({
  src,
  alt,
  className,
}: {
  src: string
  alt: string
  className?: string
}) {
  return (
    <img
      src={src}
      alt={alt}
      loading="lazy"
      onError={(e) => {
        e.currentTarget.style.display = 'none'
      }}
      // Sizing belongs to the caller — a list row wants a 64px square, a card
      // wants full width. `cn` merges rather than concatenates, so a caller's
      // `size-16` actually beats the default `w-full` instead of losing to it.
      className={cn('w-full object-cover bg-mist', className)}
    />
  )
}
