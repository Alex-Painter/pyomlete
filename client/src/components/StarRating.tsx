import { Star } from 'lucide-react'
import { cn } from '@/lib/utils'

type Props = {
  value: number | null
  onChange?: (rating: number) => void
  size?: 'default' | 'large'
  label?: string
}

export function StarRating({ value, onChange, size = 'default', label = 'Rating' }: Props) {
  return (
    <div className="flex" role="radiogroup" aria-label={label}>
      {[1, 2, 3, 4, 5].map((star) => (
        <button
          key={star}
          type="button"
          role="radio"
          aria-checked={value === star}
          aria-label={`${star} star${star === 1 ? '' : 's'}`}
          onClick={() => onChange?.(star)}
          disabled={!onChange}
          className={cn(
            'flex items-center justify-center rounded-full text-ink-faint transition-colors hover:text-[#e0a800] disabled:pointer-events-none',
            size === 'large' ? 'size-11' : 'size-9',
          )}
        >
          <Star
            className={cn(
              size === 'large' ? 'size-7' : 'size-5',
              value !== null && star <= value && 'fill-[#e0a800] text-[#e0a800]',
            )}
          />
        </button>
      ))}
    </div>
  )
}
