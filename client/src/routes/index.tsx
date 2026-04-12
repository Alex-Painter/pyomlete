import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Loader2, Plus, ShoppingCart } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { apiFetch } from '@/lib/api'

type ListSummary = {
  id: string
  name: string
  created_at: string | null
  item_count: number
  checked_count: number
  recipe_titles: string[]
}

export const Route = createFileRoute('/')({ component: ListsPage })

function ListsPage() {
  const navigate = useNavigate()
  const queryClient = useQueryClient()

  const { data: lists, isLoading } = useQuery({
    queryKey: ['lists'],
    queryFn: async (): Promise<ListSummary[]> => {
      const res = await apiFetch('/api/lists/')
      return res.json()
    },
  })

  const createList = useMutation({
    mutationFn: async () => {
      const res = await apiFetch('/api/lists/', { method: 'POST' })
      return res.json()
    },
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ['lists'] })
      navigate({ to: '/list/$listId', params: { listId: data.id } })
    },
  })

  return (
    <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900 text-white">
      <div className="max-w-2xl mx-auto px-4 py-12">
        <div className="flex items-center justify-between mb-8">
          <h1 className="text-2xl font-bold">My Lists</h1>
          <Button onClick={() => createList.mutate()} disabled={createList.isPending}>
            {createList.isPending ? (
              <Loader2 className="animate-spin" />
            ) : (
              <>
                <Plus className="size-4" />
                New List
              </>
            )}
          </Button>
        </div>

        {isLoading && (
          <div className="flex justify-center py-12">
            <Loader2 className="size-6 animate-spin text-slate-400" />
          </div>
        )}

        {lists && lists.length === 0 && (
          <div className="text-center py-16">
            <ShoppingCart className="size-12 mx-auto text-slate-600 mb-4" />
            <p className="text-slate-400 mb-4">No shopping lists yet</p>
            <Button onClick={() => createList.mutate()} disabled={createList.isPending}>
              <Plus className="size-4" />
              Create your first list
            </Button>
          </div>
        )}

        {lists && lists.length > 0 && (
          <div className="space-y-3">
            {lists.map((list) => (
              <button
                key={list.id}
                onClick={() => navigate({ to: '/list/$listId', params: { listId: list.id } })}
                className="w-full text-left bg-slate-800 border border-slate-700 rounded-lg p-4 hover:border-slate-500 transition-colors cursor-pointer"
              >
                <div className="flex items-center justify-between mb-1">
                  <h2 className="font-medium">{list.name}</h2>
                  <span className="text-sm text-slate-400">
                    {list.checked_count}/{list.item_count} items
                  </span>
                </div>

                {/* Progress bar */}
                {list.item_count > 0 && (
                  <div className="w-full h-1.5 bg-slate-700 rounded-full mb-2">
                    <div
                      className="h-full bg-emerald-500 rounded-full transition-all"
                      style={{ width: `${(list.checked_count / list.item_count) * 100}%` }}
                    />
                  </div>
                )}

                {list.recipe_titles.length > 0 && (
                  <p className="text-sm text-slate-400 truncate">
                    {list.recipe_titles.join(', ')}
                  </p>
                )}

                {list.created_at && (
                  <p className="text-xs text-slate-500 mt-1">
                    {new Date(list.created_at).toLocaleDateString()}
                  </p>
                )}
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
