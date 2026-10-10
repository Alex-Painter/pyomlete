import { useEffect, useRef, useState } from 'react'
import { Link, createFileRoute } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { AlertCircle, Camera, ImagePlus, Loader2, Sparkles, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { AddToListButton } from '@/components/AddToListButton'
import { PageHeader } from '@/components/PageHeader'
import { RecipeCard } from '@/components/RecipeCard'
import type { Recipe } from '@/components/RecipeCard'
import { useAddRecipeToList } from '@/hooks/useAddToList'
import { ApiError, apiJson } from '@/lib/api'
import '@/index.css'

export const Route = createFileRoute('/create')({ component: CreatePage })

type Saved = Recipe & { _id?: string; id?: string }

type Kind = 'link' | 'describe' | 'photos'

const LOOKS_LIKE_URL = /^https?:\/\/\S+\.\S+$/

function errorMessage(kind: Kind, error: Error): string {
  if (!(error instanceof ApiError)) return "Couldn't reach Omlete. Check your connection and try again."
  if (kind === 'link') {
    switch (error.status) {
      case 400:
        return "That link can't be fetched. Check it's a full, public recipe URL."
      case 404:
        return "Couldn't find a recipe on that page. Try the recipe's own page rather than a listing or a video."
      case 502:
        return "That site didn't respond. It may be down or blocking us. Try again in a minute."
    }
  }
  return 'Something went wrong making that recipe. Try again.'
}

/** A 409 carries the id of the recipe imported from this URL the first time. */
function alreadyImportedId(error: Error | null): string | null {
  if (!(error instanceof ApiError) || error.status !== 409) return null
  return (error.detail as { recipe_id?: string } | null)?.recipe_id ?? null
}

const PROGRESS: Record<Kind, string[]> = {
  link: ['Reading the page…', 'Sorting the ingredients…'],
  describe: ['Writing the recipe…', 'Matching ingredients…'],
  photos: ['Reading your photos…', 'Writing it up…'],
}

/**
 * Add a recipe from one field: paste a link, describe a dish or what's in
 * the fridge, or add photos of a recipe. It ends on the saved recipe with
 * "Add to list" and "Open", so the next step is one tap.
 */
function CreatePage() {
  const queryClient = useQueryClient()
  const addRecipeToList = useAddRecipeToList()
  const [text, setText] = useState('')
  const [photos, setPhotos] = useState<File[]>([])
  const [previews, setPreviews] = useState<string[]>([])
  const [phase, setPhase] = useState(0)
  const cameraRef = useRef<HTMLInputElement>(null)
  const libraryRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    const urls = photos.map((f) => URL.createObjectURL(f))
    setPreviews(urls)
    return () => urls.forEach((u) => URL.revokeObjectURL(u))
  }, [photos])

  const trimmed = text.trim()
  const kind: Kind = photos.length > 0 ? 'photos' : LOOKS_LIKE_URL.test(trimmed) ? 'link' : 'describe'

  const create = useMutation<Saved, Error, Kind>({
    mutationFn: async (k) => {
      setPhase(0)
      const advance = setTimeout(() => setPhase(1), 2500)
      try {
        if (k === 'link') {
          return await apiJson<Saved>('/api/recipes/import-from-url/', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ url: trimmed }),
          })
        }
        if (k === 'describe') {
          return await apiJson<Saved>('/api/recipes/generate/', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ prompt: trimmed }),
          })
        }
        const form = new FormData()
        photos.forEach((f) => form.append('files', f))
        form.append('group_sizes', String(photos.length))
        const recipes = await apiJson<Saved[]>('/api/recipes/extract-from-images/', {
          method: 'POST',
          body: form,
        })
        if (recipes.length === 0) throw new Error('No recipe found in those photos')
        return recipes[0]
      } finally {
        clearTimeout(advance)
      }
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['recipes'] })
      setText('')
      setPhotos([])
    },
  })

  const canSubmit = !create.isPending && (photos.length > 0 || trimmed.length > 2)
  const duplicateId = alreadyImportedId(create.error)
  const saved = create.data
  const savedId = saved?._id ?? saved?.id

  const label =
    kind === 'photos'
      ? `Read ${photos.length} photo${photos.length === 1 ? '' : 's'}`
      : kind === 'link'
        ? 'Import recipe'
        : 'Create recipe'

  return (
    <main className="min-h-screen bg-cream text-ink">
      <div className="mx-auto max-w-2xl px-4 py-6 sm:py-10">
        <PageHeader title="Add a recipe" subtitle="Paste a link, describe a dish, or snap a recipe." />

        <form
          onSubmit={(e) => {
            e.preventDefault()
            if (canSubmit) create.mutate(kind)
          }}
          className="space-y-3"
        >
          <textarea
            value={text}
            onChange={(e) => {
              setText(e.target.value)
              if (create.error || create.data) create.reset()
            }}
            rows={3}
            disabled={create.isPending || photos.length > 0}
            aria-label="Recipe link or description"
            placeholder={'https://www.bbcgoodfood.com/recipes/…\nor: something warming with the leeks and potatoes I have'}
            className="w-full resize-none rounded-2xl border border-line bg-white px-4 py-3 text-base shadow-sm outline-none placeholder:text-ink-muted focus:ring-2 focus:ring-ring disabled:opacity-60"
          />

          {previews.length > 0 && (
            <ul className="flex flex-wrap gap-2">
              {previews.map((src, i) => (
                <li key={src} className="relative">
                  <img src={src} alt={`Photo ${i + 1}`} className="size-20 rounded-xl object-cover" />
                  <button
                    type="button"
                    aria-label={`Remove photo ${i + 1}`}
                    onClick={() => setPhotos(photos.filter((_, idx) => idx !== i))}
                    className="absolute -right-2 -top-2 flex size-7 items-center justify-center rounded-full bg-ink text-white shadow"
                  >
                    <X className="size-4" />
                  </button>
                </li>
              ))}
            </ul>
          )}

          <div className="flex flex-wrap items-center gap-2">
            <input
              ref={cameraRef}
              type="file"
              accept="image/*"
              capture="environment"
              className="hidden"
              onChange={(e) => {
                setPhotos((p) => [...p, ...Array.from(e.target.files ?? [])])
                e.target.value = ''
              }}
            />
            <input
              ref={libraryRef}
              type="file"
              accept="image/*"
              multiple
              className="hidden"
              onChange={(e) => {
                setPhotos((p) => [...p, ...Array.from(e.target.files ?? [])])
                e.target.value = ''
              }}
            />
            <button
              type="button"
              onClick={() => cameraRef.current?.click()}
              disabled={create.isPending}
              className="flex min-h-[44px] items-center gap-2 rounded-xl border border-line bg-white px-3 text-sm font-medium text-ink-soft hover:bg-sand"
            >
              <Camera className="size-4" />
              Take photo
            </button>
            <button
              type="button"
              onClick={() => libraryRef.current?.click()}
              disabled={create.isPending}
              className="flex min-h-[44px] items-center gap-2 rounded-xl border border-line bg-white px-3 text-sm font-medium text-ink-soft hover:bg-sand"
            >
              <ImagePlus className="size-4" />
              Choose photos
            </button>
            <div className="flex-1" />
            <Button type="submit" disabled={!canSubmit} className="min-h-[44px] px-5 font-semibold">
              {create.isPending ? <Loader2 className="animate-spin" /> : <Sparkles className="size-4" />}
              {label}
            </Button>
          </div>
          {photos.length > 1 && (
            <p className="text-sm text-ink-muted">Several photos are read as one recipe, e.g. two pages of a cookbook.</p>
          )}
        </form>

        {create.isPending && (
          <p role="status" className="mt-6 flex items-center gap-2.5 text-ink-muted">
            <Loader2 className="size-4 animate-spin" />
            {PROGRESS[kind][phase]}
          </p>
        )}

        {duplicateId && (
          <div className="mt-6 flex items-start gap-2.5 rounded-xl border border-line bg-white p-4">
            <AlertCircle className="mt-0.5 size-4 shrink-0 text-ink-muted" />
            <p>
              You've already saved that one.{' '}
              <Link to="/recipe/$recipeId" params={{ recipeId: duplicateId }} className="font-semibold underline underline-offset-4">
                Open it
              </Link>
            </p>
          </div>
        )}

        {create.error && !duplicateId && (
          <div role="alert" className="mt-6 flex items-start gap-2.5 rounded-xl border border-line bg-white p-4">
            <AlertCircle className="mt-0.5 size-4 shrink-0 text-danger" />
            <p className="text-ink-soft">{errorMessage(create.variables, create.error)}</p>
          </div>
        )}

        {saved && savedId && (
          <div className="mt-8 space-y-3">
            <div className="flex flex-wrap items-center gap-2">
              <p className="mr-auto font-semibold text-success">Saved to your recipes</p>
              <AddToListButton onAdd={(list) => addRecipeToList(savedId, saved.title, list)} />
              <Link
                to="/recipe/$recipeId"
                params={{ recipeId: savedId }}
                className="flex min-h-[44px] items-center rounded-lg border border-line bg-white px-4 font-medium hover:bg-sand"
              >
                Open
              </Link>
            </div>
            <RecipeCard recipe={saved} />
          </div>
        )}
      </div>
    </main>
  )
}
