import { useRef, useState } from 'react'
import { createFileRoute } from '@tanstack/react-router'
import { useMutation } from '@tanstack/react-query'
import { ImageIcon, Loader2, UploadCloud, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { RecipeCard } from '@/components/RecipeCard'
import type { Recipe } from '@/components/RecipeCard'
import { apiFetch } from '@/lib/api'
import '@/index.css'

export const Route = createFileRoute('/')({ component: App })

type Tab = 'generate' | 'extract'

function App() {
  const [tab, setTab] = useState<Tab>('generate')

  return (
    <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900 text-white">
      <div className="max-w-2xl mx-auto px-4 py-12">
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

function ExtractTab() {
  const inputRef = useRef<HTMLInputElement>(null)
  const [files, setFiles] = useState<File[]>([])

  const { mutate, data, isPending } = useMutation({
    mutationFn: async (fs: File[]): Promise<Recipe[]> => {
      const form = new FormData()
      fs.forEach((f) => form.append('files', f))
      const res = await apiFetch('/api/recipes/extract-from-images/', {
        method: 'POST',
        body: form,
      })
      return res.json()
    },
  })

  const removeFile = (i: number) => setFiles((prev) => prev.filter((_, idx) => idx !== i))

  const fileLabel =
    files.length === 0
      ? 'Extract Recipes'
      : `Extract ${files.length} Recipe${files.length !== 1 ? 's' : ''}`

  return (
    <div className="space-y-6">
      <div>
        <input
          ref={inputRef}
          type="file"
          accept="image/*"
          multiple
          className="hidden"
          onChange={(e) => {
            setFiles((prev) => [...prev, ...Array.from(e.target.files ?? [])])
            e.target.value = ''
          }}
        />
        <button
          onClick={() => inputRef.current?.click()}
          className="w-full border-2 border-dashed border-slate-700 rounded-xl p-8 flex flex-col items-center gap-3 text-slate-400 hover:border-slate-500 hover:text-slate-300 transition-colors cursor-pointer"
        >
          <UploadCloud className="size-8" />
          <span className="text-sm">Click to upload images</span>
          <span className="text-xs text-slate-500">Photos of recipe books or screenshots</span>
        </button>

        {files.length > 0 && (
          <ul className="mt-3 space-y-2">
            {files.map((f, i) => (
              <li key={i} className="flex items-center gap-3 bg-slate-800 rounded-lg px-3 py-2">
                <ImageIcon className="size-4 text-slate-400 shrink-0" />
                <span className="text-sm text-slate-300 truncate flex-1">{f.name}</span>
                <button
                  onClick={() => removeFile(i)}
                  className="text-slate-500 hover:text-slate-300 cursor-pointer"
                >
                  <X className="size-4" />
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      <Button onClick={() => mutate(files)} disabled={isPending || files.length === 0}>
        {isPending ? (
          <>
            <Loader2 className="animate-spin" />
            Extracting...
          </>
        ) : (
          fileLabel
        )}
      </Button>

      {data && (
        <div className="space-y-4">
          {data.map((recipe, i) => (
            <RecipeCard key={i} recipe={recipe} />
          ))}
        </div>
      )}
    </div>
  )
}
