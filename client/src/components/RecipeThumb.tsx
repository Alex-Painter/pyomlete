import { useState } from 'react'
import { UtensilsCrossed } from 'lucide-react'
import { cn } from '@/lib/utils'

/**
 * A recipe's photo, or a consistent warm placeholder when it has none (or the
 * source's image has gone), so cards with and without photos line up.
 */
export function RecipeThumb({
  src,
  title,
  className,
}: {
  src: string | null | undefined
  title: string
  className?: string
}) {
  const [failed, setFailed] = useState(false)
  if (src && !failed) {
    return (
      <img
        src={src}
        alt=""
        loading="lazy"
        onError={() => setFailed(true)}
        className={cn('bg-mist object-cover', className)}
      />
    )
  }
  return (
    <div
      aria-hidden
      className={cn(
        'flex items-center justify-center bg-gradient-to-br from-sand to-[#f6e7c4] text-[#a07a2c]',
        className,
      )}
      title={title}
    >
      <UtensilsCrossed className="size-1/3 max-h-10 max-w-10 opacity-70" />
    </div>
  )
}
