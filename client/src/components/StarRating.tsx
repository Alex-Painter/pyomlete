import { Star } from 'lucide-react'

type Props = {
  value: number | null
  onChange?: (rating: number) => void
}

export function StarRating({ value, onChange }: Props) {
  return (
    <div className="flex gap-0.5">
      {[1, 2, 3, 4, 5].map((star) => (
        <button
          key={star}
          type="button"
          onClick={() => onChange?.(star)}
          disabled={!onChange}
          className="text-slate-500 hover:text-amber-400 disabled:cursor-default transition-colors cursor-pointer disabled:pointer-events-none"
        >
          <Star
            className={`size-5 ${
              value !== null && star <= value
                ? 'fill-amber-400 text-amber-400'
                : ''
            }`}
          />
        </button>
      ))}
    </div>
  )
}
