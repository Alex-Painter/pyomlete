import { createFileRoute } from '@tanstack/react-router'

export const Route = createFileRoute('/list/$listId')({ component: ListDetailPage })

function ListDetailPage() {
  const { listId } = Route.useParams()

  return (
    <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900 text-white">
      <div className="max-w-2xl mx-auto px-4 py-12">
        <p className="text-slate-400">List detail page — coming in next task</p>
        <p className="text-sm text-slate-500 mt-2">ID: {listId}</p>
      </div>
    </div>
  )
}
