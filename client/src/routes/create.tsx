import { useRef, useState } from 'react'
import { createFileRoute } from '@tanstack/react-router'
import { useMutation } from '@tanstack/react-query'
import { ImageIcon, Loader2, Plus, Trash2, UploadCloud, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { RecipeCard } from '@/components/RecipeCard'
import type { Recipe } from '@/components/RecipeCard'
import { apiFetch } from '@/lib/api'
import '@/index.css'

export const Route = createFileRoute('/create')({ component: CreatePage })

type Tab = 'generate' | 'extract'

function CreatePage() {
  const [tab, setTab] = useState<Tab>('extract')

  return (
    <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900 text-white">
      <div className="max-w-2xl mx-auto px-4 py-12">
        <h1 className="text-2xl font-bold mb-2">Create Recipe</h1>
        <p className="text-slate-400 mb-8">Generate or extract recipes with AI</p>

        <div className="flex gap-1 p-1 bg-slate-800 rounded-lg mb-8 w-fit">
          {(['generate', 'extract'] as const).map((t) => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className={`px-4 py-2 rounded-md text-sm font-medium transition-colors cursor-pointer ${tab === t
                  ? 'bg-slate-700 text-white shadow-sm'
                  : 'text-slate-400 hover:text-slate-200'
                }`}
            >
              {t === 'generate' ? 'Generate' : 'Extract from Images'}
            </button>
          ))}
        </div>

        {tab === 'generate' ? <GenerateTab /> : <ExtractTab />}
      </div>
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
        <label className="text-sm font-medium text-slate-300">
          What ingredients do you have?
        </label>
        <textarea
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          placeholder="e.g. eggs, crème fraîche, salt, pepper, chives..."
          rows={3}
          className="w-full bg-slate-800 border border-slate-700 rounded-lg px-4 py-3 text-sm text-white placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-slate-500 resize-none"
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
        className="w-full border-2 border-dashed border-slate-700 rounded-xl p-6 flex items-center justify-center gap-2 text-slate-400 hover:border-slate-500 hover:text-slate-300 transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
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
          <h3 className="text-sm font-medium text-slate-400">
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
    <div className="bg-slate-800 border border-slate-700 rounded-lg p-4 space-y-3">
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
              className="relative group bg-slate-700 rounded-md px-3 py-2 flex items-center gap-2"
            >
              <ImageIcon className="size-4 text-slate-400 shrink-0" />
              <span className="text-xs text-slate-300 truncate max-w-[120px]">{f.name}</span>
              <button
                onClick={() => onRemoveFile(i)}
                disabled={disabled}
                className="text-slate-500 hover:text-slate-300 cursor-pointer"
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
        className="flex items-center gap-2 text-sm text-slate-400 hover:text-slate-200 transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
      >
        <UploadCloud className="size-4" />
        Add photos
      </button>
    </div>
  )
}
