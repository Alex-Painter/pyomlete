import { forwardRef } from 'react'
import type { AnchorHTMLAttributes } from 'react'
import { createLink, useRouter } from '@tanstack/react-router'

const BackAnchor = forwardRef<HTMLAnchorElement, AnchorHTMLAttributes<HTMLAnchorElement>>(
  function BackAnchor({ onClick, ...props }, ref) {
    const router = useRouter()
    return (
      <a
        ref={ref}
        {...props}
        onClick={(e) => {
          const plainClick = e.button === 0 && !(e.metaKey || e.ctrlKey || e.shiftKey || e.altKey)
          if (plainClick && router.history.canGoBack()) {
            e.preventDefault()
            router.history.back()
            return
          }
          onClick?.(e)
        }}
      />
    )
  },
)

/**
 * A back button that returns to the screen you came from, like the iOS
 * navigation bar. Its `to` is only the fallback, for a page opened directly
 * from a link or a new tab, where there is nothing in the app to go back to.
 */
export const BackLink = createLink(BackAnchor)
