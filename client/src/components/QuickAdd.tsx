import { useEffect, useRef, useState } from 'react'
import { Mic, Plus } from 'lucide-react'
import { parseItems } from '@/lib/parseItems'
import type { ParsedItem } from '@/lib/parseItems'
import { cn } from '@/lib/utils'

type SpeechRecognitionLike = {
  lang: string
  interimResults: boolean
  onresult: ((e: { results: ArrayLike<ArrayLike<{ transcript: string }>> }) => void) | null
  onend: (() => void) | null
  start: () => void
  stop: () => void
}

function getRecognition(): SpeechRecognitionLike | null {
  if (typeof window === 'undefined') return null
  const w = window as unknown as {
    SpeechRecognition?: new () => SpeechRecognitionLike
    webkitSpeechRecognition?: new () => SpeechRecognitionLike
  }
  const Ctor = w.SpeechRecognition ?? w.webkitSpeechRecognition
  return Ctor ? new Ctor() : null
}

/**
 * One field for adding items. Understands "2 onions", "500g mince" and
 * "milk, eggs, bread"; a pasted or dictated list adds one item per line.
 * Items appear at once; nothing waits on the network.
 */
export function QuickAdd({
  onAdd,
  placeholder = 'Add items, e.g. 2 onions, 500g mince',
  className,
}: {
  onAdd: (items: ParsedItem[]) => void
  placeholder?: string
  className?: string
}) {
  const [value, setValue] = useState('')
  const [listening, setListening] = useState(false)
  const recognition = useRef<SpeechRecognitionLike | null>(null)
  // Checked after mount so the server render and the first client render agree.
  const [canDictate, setCanDictate] = useState(false)
  useEffect(() => setCanDictate(getRecognition() != null), [])

  const submit = (text = value) => {
    const items = parseItems(text)
    if (items.length === 0) return
    onAdd(items)
    setValue('')
  }

  const dictate = () => {
    if (listening) {
      recognition.current?.stop()
      return
    }
    const r = getRecognition()
    if (!r) return
    recognition.current = r
    r.lang = navigator.language || 'en-GB'
    r.interimResults = false
    r.onresult = (e) => {
      // "milk eggs and bread" → split spoken "and" into separate items too.
      const said = Array.from(e.results)
        .map((res) => res[0].transcript)
        .join(', ')
        .replace(/\s+and\s+/gi, ', ')
      submit(said)
    }
    r.onend = () => setListening(false)
    setListening(true)
    r.start()
  }

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault()
        submit()
      }}
      className={cn('flex gap-2', className)}
    >
      <div className="relative min-w-0 flex-1">
        <input
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onPaste={(e) => {
            const text = e.clipboardData.getData('text')
            // A pasted multi-line list goes straight in, one item per line.
            if (text.includes('\n')) {
              e.preventDefault()
              submit(text)
            }
          }}
          enterKeyHint="done"
          autoComplete="off"
          aria-label="Add items"
          placeholder={placeholder}
          className="h-12 w-full rounded-xl border border-line bg-white px-4 pr-12 text-base text-ink shadow-sm outline-none placeholder:text-ink-muted focus:ring-2 focus:ring-ring"
        />
        {canDictate && (
          <button
            type="button"
            onClick={dictate}
            aria-label={listening ? 'Stop dictating' : 'Dictate items'}
            aria-pressed={listening}
            className={cn(
              'absolute right-1 top-1/2 flex size-10 -translate-y-1/2 items-center justify-center rounded-lg',
              listening ? 'bg-danger text-white' : 'text-ink-muted hover:bg-sand hover:text-ink',
            )}
          >
            <Mic className="size-5" />
          </button>
        )}
      </div>
      <button
        type="submit"
        aria-label="Add"
        disabled={!value.trim()}
        className="flex size-12 shrink-0 items-center justify-center rounded-xl bg-primary text-ink shadow-sm disabled:opacity-40"
      >
        <Plus className="size-5" />
      </button>
    </form>
  )
}
