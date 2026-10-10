import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { BottomSheet } from '@/components/BottomSheet'
import { Button } from '@/components/ui/button'
import { apiJson } from '@/lib/api'

export function RenameListSheet({
  list,
  onClose,
}: {
  list: { id: string; name: string } | null
  onClose: () => void
}) {
  const queryClient = useQueryClient()
  const [name, setName] = useState('')
  const [lastId, setLastId] = useState<string | null>(null)
  if (list && list.id !== lastId) {
    setLastId(list.id)
    setName(list.name)
  }

  const save = async () => {
    const trimmed = name.trim()
    if (!list || !trimmed || trimmed === list.name) return onClose()
    onClose()
    await apiJson(`/api/lists/${list.id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: trimmed }),
    }).catch(() => {})
    void queryClient.invalidateQueries({ queryKey: ['lists'] })
    void queryClient.invalidateQueries({ queryKey: ['list', list.id] })
  }

  return (
    <BottomSheet
      open={list != null}
      onOpenChange={(o) => {
        if (!o) {
          setLastId(null)
          onClose()
        }
      }}
      title="Rename list"
    >
      <form
        onSubmit={(e) => {
          e.preventDefault()
          void save()
        }}
        className="space-y-3"
      >
        <input
          autoFocus
          value={name}
          onChange={(e) => setName(e.target.value)}
          aria-label="List name"
          placeholder="e.g. Week of the 12th"
          className="h-12 w-full rounded-xl border border-line bg-cream px-3 text-base outline-none focus:ring-2 focus:ring-ring"
        />
        <Button type="submit" className="min-h-[48px] w-full text-base font-semibold">
          Save
        </Button>
      </form>
    </BottomSheet>
  )
}
