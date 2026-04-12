import { useState } from 'react'
import { createFileRoute } from '@tanstack/react-router'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  ArrowDown,
  ArrowUp,
  GripVertical,
  Loader2,
  Pencil,
  Plus,
  Trash2,
  X,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { apiFetch } from '@/lib/api'

type CategoryConfig = {
  name: string
  order: number
}

export const Route = createFileRoute('/settings')({ component: SettingsPage })

function SettingsPage() {
  const queryClient = useQueryClient()
  const [newCategoryName, setNewCategoryName] = useState('')
  const [editingIndex, setEditingIndex] = useState<number | null>(null)
  const [editName, setEditName] = useState('')

  const { data: categories, isLoading } = useQuery({
    queryKey: ['categories'],
    queryFn: async (): Promise<CategoryConfig[]> => {
      const res = await apiFetch('/api/settings/categories')
      return res.json()
    },
  })

  const updateCategories = useMutation({
    mutationFn: async (cats: CategoryConfig[]) => {
      const res = await apiFetch('/api/settings/categories', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ categories: cats }),
      })
      return res.json()
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['categories'] })
    },
  })

  const sorted = categories ? [...categories].sort((a, b) => a.order - b.order) : []

  const handleAdd = () => {
    const name = newCategoryName.trim()
    if (!name || !categories) return
    if (sorted.some((c) => c.name.toLowerCase() === name.toLowerCase())) return
    const maxOrder = sorted.length > 0 ? Math.max(...sorted.map((c) => c.order)) : -1
    const updated = [...sorted, { name, order: maxOrder + 1 }]
    updateCategories.mutate(updated)
    setNewCategoryName('')
  }

  const handleDelete = (index: number) => {
    if (!confirm(`Delete "${sorted[index].name}"?`)) return
    const updated = sorted.filter((_, i) => i !== index).map((c, i) => ({ ...c, order: i }))
    updateCategories.mutate(updated)
  }

  const handleMove = (index: number, direction: 'up' | 'down') => {
    const swapIndex = direction === 'up' ? index - 1 : index + 1
    if (swapIndex < 0 || swapIndex >= sorted.length) return
    const updated = [...sorted]
    ;[updated[index], updated[swapIndex]] = [updated[swapIndex], updated[index]]
    updateCategories.mutate(updated.map((c, i) => ({ ...c, order: i })))
  }

  const handleRename = (index: number) => {
    const name = editName.trim()
    if (!name) return
    const updated = sorted.map((c, i) => (i === index ? { ...c, name } : c))
    updateCategories.mutate(updated)
    setEditingIndex(null)
  }

  return (
    <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900 text-white">
      <div className="max-w-lg mx-auto px-4 py-12">
        <h1 className="text-2xl font-bold mb-8">Settings</h1>

        <div className="space-y-6">
          <div>
            <h2 className="text-lg font-semibold mb-1">Categories</h2>
            <p className="text-sm text-slate-400 mb-4">
              Manage how items are grouped on your shopping lists. Drag to reorder.
            </p>

            {isLoading && (
              <div className="flex justify-center py-8">
                <Loader2 className="size-6 animate-spin text-slate-400" />
              </div>
            )}

            {sorted.length > 0 && (
              <div className="space-y-1 mb-4">
                {sorted.map((cat, index) => (
                  <div
                    key={cat.name}
                    className="flex items-center gap-2 bg-slate-800 border border-slate-700 rounded-md px-3 py-2.5"
                  >
                    <GripVertical className="size-4 text-slate-600 shrink-0" />

                    {editingIndex === index ? (
                      <form
                        className="flex-1 flex gap-2"
                        onSubmit={(e) => {
                          e.preventDefault()
                          handleRename(index)
                        }}
                      >
                        <Input
                          value={editName}
                          onChange={(e) => setEditName(e.target.value)}
                          className="h-7 bg-slate-700 border-slate-600 text-white text-sm"
                          autoFocus
                          onKeyDown={(e) => {
                            if (e.key === 'Escape') setEditingIndex(null)
                          }}
                        />
                        <Button type="submit" size="sm" className="h-7">
                          Save
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          className="h-7 text-slate-400"
                          onClick={() => setEditingIndex(null)}
                        >
                          <X className="size-3.5" />
                        </Button>
                      </form>
                    ) : (
                      <>
                        <span className="flex-1 text-sm">{cat.name}</span>
                        <div className="flex items-center gap-0.5">
                          <Button
                            variant="ghost"
                            size="icon-xs"
                            onClick={() => handleMove(index, 'up')}
                            disabled={index === 0}
                            className="text-slate-500 hover:text-white"
                          >
                            <ArrowUp className="size-3.5" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon-xs"
                            onClick={() => handleMove(index, 'down')}
                            disabled={index === sorted.length - 1}
                            className="text-slate-500 hover:text-white"
                          >
                            <ArrowDown className="size-3.5" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon-xs"
                            onClick={() => {
                              setEditingIndex(index)
                              setEditName(cat.name)
                            }}
                            className="text-slate-500 hover:text-white"
                          >
                            <Pencil className="size-3.5" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon-xs"
                            onClick={() => handleDelete(index)}
                            className="text-slate-500 hover:text-red-400"
                          >
                            <Trash2 className="size-3.5" />
                          </Button>
                        </div>
                      </>
                    )}
                  </div>
                ))}
              </div>
            )}

            {/* Add new category */}
            <form
              onSubmit={(e) => {
                e.preventDefault()
                handleAdd()
              }}
              className="flex gap-2"
            >
              <Input
                value={newCategoryName}
                onChange={(e) => setNewCategoryName(e.target.value)}
                placeholder="New category name..."
                className="flex-1 bg-slate-800 border-slate-700 text-white placeholder:text-slate-500"
              />
              <Button type="submit" disabled={!newCategoryName.trim() || updateCategories.isPending}>
                <Plus className="size-4" />
                Add
              </Button>
            </form>
          </div>
        </div>
      </div>
    </div>
  )
}
