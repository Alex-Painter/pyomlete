import { Button } from '@/components/ui/button'
import { useQuery } from '@tanstack/react-query'
import { createFileRoute } from '@tanstack/react-router'
import '@/index.css';

export const Route = createFileRoute('/')({ component: App })

function App() {

  const { data, refetch } = useQuery({
    queryKey: ['recipe-generation'],
    queryFn: async () => {
      const response = await fetch('/api/recipes/generate/', {
        method: 'POST',
        body: JSON.stringify({ "prompt": 'Chopped tomatoes, pasta' }),
        headers: {
          'Content-Type': 'application/json'
        }
      })
      return response.json()
    },
    enabled: false,
    retry: false,
  })

  return (
    <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900">
      <Button onClick={() => refetch()}>Click me</Button>
    </div>
  )
}
