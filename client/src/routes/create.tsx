import { useRef, useState } from 'react'
import { Link, createFileRoute } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import {
  AlertCircle,
  ImageIcon,
  Link2,
  Loader2,
  Plus,
  Trash2,
  UploadCloud,
  X,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { RecipeCard } from '@/components/RecipeCard'
import type { Recipe } from '@/components/RecipeCard'
import { ApiError, apiFetch, apiJson } from '@/lib/api'
import '@/index.css'

export const Route = createFileRoute('/create')({ component: CreatePage })

type Tab = 'link' | 'generate' | 'extract'

const TAB_LABELS: Record<Tab, string> = {
  link: 'From link',
  generate: 'Generate',
  extract: 'Extract from Images',
}

function CreatePage() {
  // Pasting a link is the most common way people acquire a recipe, so it leads.
  const [tab, setTab] = useState<Tab>('link')

  return (
    <div className="min-h-screen bg-cream text-ink">
      <div className="max-w-2xl mx-auto px-4 py-12">
        <h1 className="text-2xl font-bold mb-2">Create Recipe</h1>
        <p className="text-ink-muted mb-8">
          Import a recipe from a link, or make one with AI
        </p>

        <div className="flex flex-wrap gap-1 p-1 bg-mist rounded-lg mb-8 w-fit">
          {(['link', 'generate', 'extract'] as const).map((t) => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className={`px-4 py-2 rounded-md text-sm font-medium transition-colors cursor-pointer ${tab === t
                  ? 'bg-white text-ink shadow-sm'
                  : 'text-ink-muted hover:text-ink-soft'
                }`}
            >
              {TAB_LABELS[t]}
            </button>
          ))}
        </div>

        {tab === 'link' && <LinkTab />}
        {tab === 'generate' && <GenerateTab />}
        {tab === 'extract' && <ExtractTab />}
      </div>
    </div>
  )
}

type ImportedRecipe = Recipe & { _id: string }

// The two stages the server runs, in order. We can't observe the handover — the
// request is a single round trip — so the copy advances on a timer sized to a
// typical scrape. It tells the user what is happening, not when it happened.
const SORTING_COPY_DELAY_MS = 2500

type ImportPhase = 'reading' | 'sorting'

function importErrorMessage(error: Error): string {
  if (!(error instanceof ApiError)) {
    return 'Could not reach Omlete. Check your connection and try again.'
  }

  switch (error.status) {
    case 400:
      return "That link can't be fetched. Check it's a full, public recipe URL."
    case 404:
      return "Couldn't find a recipe on that page. Try the recipe's own page rather than a listing or a video."
    case 502:
      return "That site didn't respond. It may be down or blocking us — try again in a minute."
    default:
      return 'Something went wrong importing that link. Try again.'
  }
}

/** A 409 carries the id of the recipe imported from this URL the first time. */
function alreadyImportedId(error: Error | null): string | null {
  if (!(error instanceof ApiError) || error.status !== 409) return null
  const detail = error.detail as { recipe_id?: string } | null
  return detail?.recipe_id ?? null
}

function LinkTab() {
  const queryClient = useQueryClient()
  const [url, setUrl] = useState('')
  const [phase, setPhase] = useState<ImportPhase>('reading')

  const { mutate, data, isPending, error, reset } = useMutation<
    ImportedRecipe,
    Error,
    string
  >({
    mutationFn: async (target) => {
      setPhase('reading')
      const advance = setTimeout(() => setPhase('sorting'), SORTING_COPY_DELAY_MS)
      try {
        return await apiJson<ImportedRecipe>('/api/recipes/import-from-url/', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ url: target }),
        })
      } finally {
        clearTimeout(advance)
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['recipes'] })
    },
  })

  const trimmed = url.trim()
  const looksLikeUrl = /^https?:\/\/\S+\.\S+/.test(trimmed)
  const duplicateId = alreadyImportedId(error)

  const submit = () => {
    if (!looksLikeUrl || isPending) return
    mutate(trimmed)
  }

  return (
    <div className="space-y-6">
      <div className="space-y-2">
        <label htmlFor="import-url" className="text-sm font-medium text-ink-soft">
          Paste a recipe link
        </label>
        <div className="flex gap-2">
          <div className="relative flex-1">
            <Link2 className="size-4 text-ink-faint absolute left-3 top-1/2 -translate-y-1/2 pointer-events-none" />
            <input
              id="import-url"
              type="url"
              inputMode="url"
              value={url}
              onChange={(e) => {
                setUrl(e.target.value)
                if (error || data) reset()
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter') submit()
              }}
              placeholder="https://www.bbcgoodfood.com/recipes/..."
              disabled={isPending}
              className="w-full bg-white border border-line rounded-lg pl-9 pr-4 py-3 text-sm text-ink placeholder-ink-faint focus:outline-none focus:ring-2 focus:ring-primary disabled:opacity-60"
            />
          </div>
          <Button onClick={submit} disabled={isPending || !looksLikeUrl}>
            {isPending ? <Loader2 className="animate-spin" /> : 'Import'}
          </Button>
        </div>
        {trimmed !== '' && !looksLikeUrl && (
          <p className="text-xs text-ink-muted">
            That doesn't look like a link — it should start with https://
          </p>
        )}
      </div>

      {isPending && (
        <div className="flex items-center gap-2.5 text-sm text-ink-muted">
          <Loader2 className="size-4 animate-spin shrink-0" />
          {phase === 'reading'
            ? 'Reading the page…'
            : 'Sorting the ingredients…'}
        </div>
      )}

      {duplicateId && (
        <div className="flex items-start gap-2.5 rounded-lg border border-line bg-white p-4 text-sm">
          <AlertCircle className="size-4 text-ink-muted shrink-0 mt-0.5" />
          <div className="space-y-1">
            <p className="text-ink-soft">You've already imported that link.</p>
            <Link
              to="/recipe/$recipeId"
              params={{ recipeId: duplicateId }}
              className="text-ink font-medium underline underline-offset-4 hover:text-ink-soft"
            >
              Open the recipe
            </Link>
          </div>
        </div>
      )}

      {error && !duplicateId && (
        <div className="flex items-start gap-2.5 rounded-lg border border-line bg-white p-4 text-sm">
          <AlertCircle className="size-4 text-red-500 shrink-0 mt-0.5" />
          <p className="text-ink-soft">{importErrorMessage(error)}</p>
        </div>
      )}

      {data && (
        <div className="space-y-3">
          <RecipeCard recipe={data} />
          <Link
            to="/recipe/$recipeId"
            params={{ recipeId: data._id }}
            className="inline-block text-sm text-ink-soft hover:text-ink underline underline-offset-4"
          >
            Open in your recipes
          </Link>
        </div>
      )}
    </div>
  )
}

function GenerateTab() {
  const [prompt, setPrompt] = useState('')

  const { mutate, data, isPending } = useMutation({
    mutationFn: async (p: string): Promise<Recipe> => {
      const res = await apiFetch('/api/recipes/generate/', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ prompt: p }),
      })
      return res.json()
    },
  })

  return (
    <div className="space-y-6">
      <div className="space-y-2">
        <label className="text-sm font-medium text-ink-soft">
          What ingredients do you have?
        </label>
        <textarea
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          placeholder="e.g. eggs, crème fraîche, salt, pepper, chives..."
          rows={3}
          className="w-full bg-white border border-line rounded-lg px-4 py-3 text-sm text-ink placeholder-ink-faint focus:outline-none focus:ring-2 focus:ring-primary resize-none"
        />
      </div>

      <Button onClick={() => mutate(prompt)} disabled={isPending || !prompt.trim()}>
        {isPending ? (
          <>
            <Loader2 className="animate-spin" />
            Generating...
          </>
        ) : (
          'Generate Recipe'
        )}
      </Button>

      {data && <RecipeCard recipe={data} />}
    </div>
  )
}

type RecipeGroup = {
  id: string
  files: File[]
}

function ExtractTab() {
  const [groups, setGroups] = useState<RecipeGroup[]>([])
  const [results, setResults] = useState<Recipe[]>([])
  const [isExtracting, setIsExtracting] = useState(false)
  const [progress, setProgress] = useState<number>(0)

  const addGroup = () => {
    setGroups((prev) => [...prev, { id: crypto.randomUUID(), files: [] }])
  }

  const removeGroup = (groupId: string) => {
    setGroups((prev) => prev.filter((g) => g.id !== groupId))
  }

  const addFilesToGroup = (groupId: string, newFiles: File[]) => {
    setGroups((prev) =>
      prev.map((g) => (g.id === groupId ? { ...g, files: [...g.files, ...newFiles] } : g))
    )
  }

  const removeFileFromGroup = (groupId: string, fileIndex: number) => {
    setGroups((prev) =>
      prev.map((g) =>
        g.id === groupId ? { ...g, files: g.files.filter((_, i) => i !== fileIndex) } : g
      )
    )
  }

  const totalFiles = groups.reduce((sum, g) => sum + g.files.length, 0)

  const handleExtract = async () => {
    if (groups.length === 0 || totalFiles === 0) return
    setIsExtracting(true)
    setResults([])
    setProgress(0)

    for (let i = 0; i < groups.length; i++) {
      const group = groups[i]
      if (group.files.length === 0) continue
      setProgress(i + 1)

      const form = new FormData()
      group.files.forEach((f) => form.append('files', f))
      form.append('group_sizes', String(group.files.length))

      try {
        const res = await apiFetch('/api/recipes/extract-from-images/', {
          method: 'POST',
          body: form,
        })
        const recipes: Recipe[] = await res.json()
        setResults((prev) => [...prev, ...recipes])
      } catch {
        // Continue with next group on error
      }
    }

    setIsExtracting(false)
  }

  return (
    <div className="space-y-6">
      {/* Recipe groups */}
      {groups.map((group, groupIndex) => (
        <RecipeGroupRow
          key={group.id}
          index={groupIndex}
          group={group}
          onAddFiles={(files) => addFilesToGroup(group.id, files)}
          onRemoveFile={(fileIndex) => removeFileFromGroup(group.id, fileIndex)}
          onRemoveGroup={() => removeGroup(group.id)}
          disabled={isExtracting}
        />
      ))}

      {/* Add recipe button */}
      <button
        onClick={addGroup}
        disabled={isExtracting}
        className="w-full border-2 border-dashed border-line rounded-xl p-6 flex items-center justify-center gap-2 text-ink-muted hover:border-primary hover:text-ink-soft transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
      >
        <Plus className="size-5" />
        <span className="text-sm font-medium">Add Recipe</span>
      </button>

      {/* Extract button */}
      {groups.length > 0 && (
        <Button
          onClick={handleExtract}
          disabled={isExtracting || totalFiles === 0}
          className="w-full"
        >
          {isExtracting ? (
            <>
              <Loader2 className="animate-spin" />
              Extracting recipe {progress} of {groups.length}...
            </>
          ) : (
            `Create ${groups.length} Recipe${groups.length !== 1 ? 's' : ''}`
          )}
        </Button>
      )}

      {/* Results */}
      {results.length > 0 && (
        <div className="space-y-4">
          <h3 className="text-sm font-medium text-ink-muted">
            Extracted {results.length} recipe{results.length !== 1 ? 's' : ''}
          </h3>
          {results.map((recipe, i) => (
            <RecipeCard key={i} recipe={recipe} />
          ))}
        </div>
      )}
    </div>
  )
}

function RecipeGroupRow({
  index,
  group,
  onAddFiles,
  onRemoveFile,
  onRemoveGroup,
  disabled,
}: {
  index: number
  group: RecipeGroup
  onAddFiles: (files: File[]) => void
  onRemoveFile: (fileIndex: number) => void
  onRemoveGroup: () => void
  disabled: boolean
}) {
  const inputRef = useRef<HTMLInputElement>(null)

  return (
    <div className="bg-white border border-line rounded-lg p-4 space-y-3 shadow-sm">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-medium">Recipe {index + 1}</h3>
        <Button
          variant="ghost"
          size="icon-xs"
          onClick={onRemoveGroup}
          disabled={disabled}
          className="text-slate-500 hover:text-red-400"
        >
          <Trash2 className="size-4" />
        </Button>
      </div>

      {/* Photo thumbnails */}
      {group.files.length > 0 && (
        <div className="flex flex-wrap gap-2">
          {group.files.map((f, i) => (
            <div
              key={i}
              className="relative group bg-cream rounded-md px-3 py-2 flex items-center gap-2"
            >
              <ImageIcon className="size-4 text-ink-muted shrink-0" />
              <span className="text-xs text-ink-soft truncate max-w-[120px]">{f.name}</span>
              <button
                onClick={() => onRemoveFile(i)}
                disabled={disabled}
                className="text-ink-faint hover:text-ink-muted cursor-pointer"
              >
                <X className="size-3.5" />
              </button>
            </div>
          ))}
        </div>
      )}

      {/* Add photos button */}
      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        multiple
        className="hidden"
        onChange={(e) => {
          onAddFiles(Array.from(e.target.files ?? []))
          e.target.value = ''
        }}
      />
      <button
        onClick={() => inputRef.current?.click()}
        disabled={disabled}
        className="flex items-center gap-2 text-sm text-ink-muted hover:text-ink-soft transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
      >
        <UploadCloud className="size-4" />
        Add photos
      </button>
    </div>
  )
}
