/**
 * Chef beside every screen (docs/PRD_CHEF.md). On a wide window it's a
 * sidebar on the right. On a phone it's a sheet over the current screen at
 * one of three heights: a slim bar, half height with the screen behind still
 * usable, or full height. The Chef tab opens it.
 *
 * Chef acts at once and every change comes with Undo, so nothing here asks
 * before doing.
 */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from 'react'
import type { ReactNode } from 'react'
import { Link, useRouterState } from '@tanstack/react-router'
import { useQueryClient } from '@tanstack/react-query'
import {
  ArrowUp,
  ChefHat,
  Globe,
  ImagePlus,
  Loader2,
  RotateCcw,
  SquarePen,
  X,
} from 'lucide-react'
import { useUndo } from '@/components/UndoToast'
import { ApiError } from '@/lib/api'
import { askChef, changesIn, newChatId, undoChange } from '@/lib/chef'
import type { ChefChange, ChefMessage, ChefPart } from '@/lib/chef'
import { cn } from '@/lib/utils'

/** closed, or the sheet's height on a phone. A wide window shows it whole. */
export type ChefHeight = 'closed' | 'bar' | 'half' | 'full'

type ChefState = {
  height: ChefHeight
  setHeight: (h: ChefHeight) => void
  /** Open, or close if it's open: the Chef tab and the Chef button. */
  toggle: () => void
}

const ChefContext = createContext<ChefState>({
  height: 'closed',
  setHeight: () => {},
  toggle: () => {},
})

export function useChef() {
  return useContext(ChefContext)
}

const WIDE = '(min-width: 1024px)'

function useWide() {
  const [wide, setWide] = useState(false)
  useEffect(() => {
    const mq = window.matchMedia(WIDE)
    setWide(mq.matches)
    const on = () => setWide(mq.matches)
    mq.addEventListener('change', on)
    return () => mq.removeEventListener('change', on)
  }, [])
  return wide
}

export function ChefProvider({ children }: { children: ReactNode }) {
  const [height, setHeight] = useState<ChefHeight>('closed')
  const toggle = useCallback(
    () => setHeight((h) => (h === 'closed' ? 'half' : 'closed')),
    [],
  )
  const open = height !== 'closed'
  return (
    <ChefContext.Provider value={{ height, setHeight, toggle }}>
      {/* The sidebar takes its width from the page rather than covering it. */}
      <div className={cn('transition-[padding]', open && 'lg:pr-[380px]')}>
        {children}
      </div>
      <Chef />
    </ChefContext.Provider>
  )
}

const MAX_PHOTO_BYTES = 5 * 1024 * 1024

function readAsDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result))
    reader.onerror = () => reject(reader.error)
    reader.readAsDataURL(file)
  })
}

/**
 * The chat and what it changed. `inView` is true while the conversation is
 * on screen with its own Undo buttons; the toast would only cover them then.
 */
function useConversation(inView: boolean) {
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const queryClient = useQueryClient()
  const showUndo = useUndo()
  const [chatId, setChatId] = useState(newChatId)
  const [messages, setMessages] = useState<ChefMessage[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [undone, setUndone] = useState<Set<string>>(new Set())
  const abort = useRef<AbortController | null>(null)
  const inViewRef = useRef(inView)
  inViewRef.current = inView

  const refreshData = useCallback(
    () => void queryClient.invalidateQueries(),
    [queryClient],
  )

  /** Undo changes newest first, so each one finds what it left. */
  const undo = useCallback(
    async (changes: ChefChange[]) => {
      try {
        for (const c of [...changes].reverse()) {
          await undoChange(c.undo)
          setUndone((s) => new Set(s).add(c.undo))
        }
        if (!inViewRef.current) {
          showUndo({
            message:
              changes.length === 1
                ? `Undid: ${changes[0].done}`
                : 'Undid those changes',
          })
        }
      } catch (e) {
        const message =
          e instanceof ApiError && e.status === 409
            ? "That's changed since, so it can't be undone"
            : "Couldn't undo that. Try again?"
        if (inViewRef.current) setError(message)
        else showUndo({ message })
      }
      refreshData()
    },
    [refreshData, showUndo],
  )

  const send = useCallback(
    async (text: string, photos: { mediaType: string; url: string }[]) => {
      const user: ChefMessage = {
        id: crypto.randomUUID(),
        role: 'user',
        parts: [
          ...photos.map((p) => ({ type: 'file' as const, ...p })),
          ...(text ? [{ type: 'text' as const, text }] : []),
        ],
      }
      const history = [...messages, user]
      setMessages(history)
      setBusy(true)
      setError(null)
      abort.current = new AbortController()
      let seenChanges = 0
      try {
        const reply = await askChef({
          chatId,
          messages: history,
          path: pathname,
          signal: abort.current.signal,
          onReply: (r) => {
            setMessages([...history, r])
            const n = changesIn(r).length
            // Show each change on screen as soon as it lands.
            if (n > seenChanges) {
              seenChanges = n
              refreshData()
            }
          },
        })
        const changes = changesIn(reply)
        if (changes.length && !inViewRef.current) {
          showUndo({
            message:
              changes.length === 1
                ? changes[0].done
                : `${changes.length} changes`,
            onUndo: () => void undo(changes),
            duration: 8000,
          })
        }
      } catch (e) {
        if (!(e instanceof DOMException && e.name === 'AbortError')) {
          setError(
            navigator.onLine
              ? "Chef couldn't answer. Try again?"
              : 'Chef needs a connection.',
          )
        }
      } finally {
        setBusy(false)
        abort.current = null
      }
    },
    [chatId, messages, pathname, refreshData, showUndo, undo],
  )

  const reset = useCallback(() => {
    abort.current?.abort()
    setMessages([])
    setError(null)
    setChatId(newChatId())
  }, [])

  return { messages, busy, error, undone, send, undo, reset }
}

function Chef() {
  const { height, setHeight } = useChef()
  const wide = useWide()
  // Shop and Cook take the whole phone screen, with no tab bar to sit on.
  const fullscreen = useRouterState({
    select: (st) => /^\/(shop|cook)\//.test(st.location.pathname),
  })
  const convo = useConversation(
    wide
      ? height !== 'closed'
      : !fullscreen && (height === 'half' || height === 'full'),
  )

  if (height === 'closed' || (fullscreen && !wide)) return null

  if (wide) {
    return (
      <aside
        aria-label="Chef"
        className="fixed inset-y-0 right-0 z-40 flex w-[380px] flex-col border-l border-line bg-white"
      >
        <Header onClose={() => setHeight('closed')} onReset={convo.reset} />
        <Conversation {...convo} />
      </aside>
    )
  }

  return <PhoneSheet height={height} setHeight={setHeight} convo={convo} />
}

const SHEET_HEIGHTS: Record<Exclude<ChefHeight, 'closed'>, string> = {
  bar: 'h-16',
  half: 'h-[50dvh]',
  full: 'h-[calc(100dvh-3.5rem-env(safe-area-inset-bottom)-env(safe-area-inset-top)-0.5rem)]',
}

/**
 * The phone sheet. It has no backdrop, so at half height the screen above
 * still scrolls and taps. Drag the grabber, or tap it, to change height.
 */
function PhoneSheet({
  height,
  setHeight,
  convo,
}: {
  height: Exclude<ChefHeight, 'closed'>
  setHeight: (h: ChefHeight) => void
  convo: ReturnType<typeof useConversation>
}) {
  const drag = useRef<{ y: number } | null>(null)
  const order: Exclude<ChefHeight, 'closed'>[] = ['bar', 'half', 'full']

  const end = (y: number) => {
    const start = drag.current
    drag.current = null
    if (!start) return
    const dy = y - start.y
    const i = order.indexOf(height)
    if (Math.abs(dy) < 8) {
      // A tap: the bar opens to half, anything else steps down.
      setHeight(height === 'bar' ? 'half' : height === 'full' ? 'half' : 'full')
    } else if (dy < 0) {
      setHeight(order[Math.min(i + 1, 2)])
    } else {
      setHeight(i === 0 ? 'closed' : order[i - 1])
    }
  }

  const last = [...convo.messages].reverse().find((m) => m.role === 'assistant')
  const lastText = last?.parts.filter((p) => p.type === 'text').at(-1)

  return (
    <section
      aria-label="Chef"
      className={cn(
        'fixed inset-x-0 z-[55] flex flex-col rounded-t-2xl border-t border-line bg-white shadow-[0_-8px_24px_rgba(0,0,0,0.08)] transition-[height] duration-200',
        'bottom-[calc(3.5rem+env(safe-area-inset-bottom))] sm:bottom-0',
        SHEET_HEIGHTS[height],
      )}
    >
      <button
        type="button"
        aria-label={height === 'bar' ? 'Open Chef' : 'Resize Chef'}
        className="flex h-6 w-full shrink-0 touch-none items-center justify-center"
        onPointerDown={(e) => {
          drag.current = { y: e.clientY }
          e.currentTarget.setPointerCapture(e.pointerId)
        }}
        onPointerUp={(e) => end(e.clientY)}
        onPointerCancel={() => (drag.current = null)}
      >
        <span className="h-1.5 w-10 rounded-full bg-line" />
      </button>
      {height === 'bar' ? (
        <button
          type="button"
          onClick={() => setHeight('half')}
          className="flex min-h-[40px] items-center gap-2 px-4 pb-2 text-left text-sm"
        >
          <ChefHat className="size-5 shrink-0" />
          <span className="min-w-0 flex-1 truncate text-ink-soft">
            {convo.busy
              ? 'Chef is working…'
              : lastText?.type === 'text' && lastText.text
                ? lastText.text
                : 'Ask Chef'}
          </span>
        </button>
      ) : (
        <>
          <Header onClose={() => setHeight('closed')} onReset={convo.reset} />
          <Conversation {...convo} />
        </>
      )}
    </section>
  )
}

function Header({
  onClose,
  onReset,
}: {
  onClose: () => void
  onReset: () => void
}) {
  return (
    <div className="flex shrink-0 items-center gap-2 border-b border-line px-4 py-2">
      <ChefHat className="size-5" />
      <h2 className="flex-1 text-base font-semibold">Chef</h2>
      <button
        type="button"
        aria-label="New chat"
        onClick={onReset}
        className="flex size-10 items-center justify-center rounded-full text-ink-muted hover:bg-sand hover:text-ink"
      >
        <SquarePen className="size-5" />
      </button>
      <button
        type="button"
        aria-label="Close Chef"
        onClick={onClose}
        className="-mr-2 flex size-10 items-center justify-center rounded-full text-ink-muted hover:bg-sand hover:text-ink"
      >
        <X className="size-5" />
      </button>
    </div>
  )
}

function Conversation({
  messages,
  busy,
  error,
  undone,
  send,
  undo,
}: ReturnType<typeof useConversation>) {
  const [text, setText] = useState('')
  const [photos, setPhotos] = useState<{ mediaType: string; url: string }[]>([])
  const [photoError, setPhotoError] = useState<string | null>(null)
  const end = useRef<HTMLDivElement>(null)
  const fileInput = useRef<HTMLInputElement>(null)

  useEffect(() => {
    end.current?.scrollIntoView({ block: 'end' })
  }, [messages, busy])

  const submit = () => {
    const t = text.trim()
    if ((!t && !photos.length) || busy) return
    setText('')
    setPhotos([])
    void send(t, photos)
  }

  const addPhotos = async (files: FileList | null) => {
    setPhotoError(null)
    const picked = [...(files ?? [])].filter((f) => f.type.startsWith('image/'))
    if (picked.some((f) => f.size > MAX_PHOTO_BYTES)) {
      setPhotoError('Each photo can be up to 5 MB.')
      return
    }
    const read = await Promise.all(
      picked.map(async (f) => ({
        mediaType: f.type,
        url: await readAsDataUrl(f),
      })),
    )
    setPhotos((p) => [...p, ...read].slice(0, 6))
  }

  return (
    <>
      <div className="min-h-0 flex-1 space-y-3 overflow-y-auto overscroll-contain px-4 py-3">
        {messages.length === 0 && (
          <div className="py-6 text-sm text-ink-muted">
            <p className="mb-2 font-medium text-ink-soft">
              What can I do for you?
            </p>
            <p>
              Find a recipe and put it on a list, add things to the list you're
              on, or save a recipe from a photo.
            </p>
            <p className="mt-2">
              Prefer a form?{' '}
              <Link
                to="/create"
                className="font-medium text-ink underline underline-offset-4"
              >
                Add a recipe yourself
              </Link>
            </p>
          </div>
        )}
        {messages.map((m) => (
          <Message
            key={m.id}
            message={m}
            undone={undone}
            onUndo={(c) => void undo([c])}
          />
        ))}
        {busy && messages.at(-1)?.role === 'user' && (
          <Loader2
            className="size-4 animate-spin text-ink-muted"
            aria-label="Chef is thinking"
          />
        )}
        {error && <p className="text-sm text-danger">{error}</p>}
        <div ref={end} />
      </div>

      <form
        className="shrink-0 border-t border-line px-3 py-2"
        onSubmit={(e) => {
          e.preventDefault()
          submit()
        }}
      >
        {photos.length > 0 && (
          <div className="mb-2 flex gap-2 overflow-x-auto">
            {photos.map((p, i) => (
              <button
                key={i}
                type="button"
                aria-label="Remove photo"
                onClick={() => setPhotos((ps) => ps.filter((_, j) => j !== i))}
                className="relative size-14 shrink-0 overflow-hidden rounded-lg"
              >
                <img src={p.url} alt="" className="size-full object-cover" />
                <X className="absolute right-0.5 top-0.5 size-4 rounded-full bg-black/60 text-white" />
              </button>
            ))}
          </div>
        )}
        {photoError && <p className="mb-1 text-xs text-danger">{photoError}</p>}
        <div className="flex items-end gap-2">
          <button
            type="button"
            aria-label="Add photos"
            onClick={() => fileInput.current?.click()}
            className="flex size-10 shrink-0 items-center justify-center rounded-full text-ink-muted hover:bg-sand hover:text-ink"
          >
            <ImagePlus className="size-5" />
          </button>
          <input
            ref={fileInput}
            type="file"
            accept="image/*"
            multiple
            hidden
            onChange={(e) => {
              void addPhotos(e.target.files)
              e.target.value = ''
            }}
          />
          <textarea
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault()
                submit()
              }
            }}
            rows={1}
            placeholder="Ask Chef"
            aria-label="Message Chef"
            className="max-h-32 min-h-[40px] flex-1 resize-none rounded-2xl border border-line bg-cream px-3 py-2 text-base outline-none focus:border-ink-faint sm:text-sm"
          />
          <button
            type="submit"
            aria-label="Send"
            disabled={busy || (!text.trim() && !photos.length)}
            className="flex size-10 shrink-0 items-center justify-center rounded-full bg-primary text-ink disabled:opacity-40"
          >
            <ArrowUp className="size-5" />
          </button>
        </div>
      </form>
    </>
  )
}

function Message({
  message,
  undone,
  onUndo,
}: {
  message: ChefMessage
  undone: Set<string>
  onUndo: (c: ChefChange) => void
}) {
  if (message.role === 'user') {
    return (
      <div className="ml-8 flex flex-col items-end gap-1">
        {message.parts.map((p, i) =>
          p.type === 'file' ? (
            <img key={i} src={p.url} alt="" className="max-h-32 rounded-xl" />
          ) : p.type === 'text' ? (
            <p
              key={i}
              className="whitespace-pre-wrap rounded-2xl bg-sand px-3 py-2 text-sm"
            >
              {p.text}
            </p>
          ) : null,
        )}
      </div>
    )
  }
  return (
    <div className="mr-4 space-y-1.5 text-sm">
      {message.parts.map((p, i) => (
        <AssistantPart key={i} part={p} undone={undone} onUndo={onUndo} />
      ))}
    </div>
  )
}

function AssistantPart({
  part,
  undone,
  onUndo,
}: {
  part: ChefPart
  undone: Set<string>
  onUndo: (c: ChefChange) => void
}) {
  if (part.type === 'text')
    return part.text ? <p className="whitespace-pre-wrap">{part.text}</p> : null
  if (part.type !== 'tool') return null

  if (part.state === 'running') {
    return (
      <p className="flex items-center gap-1.5 text-xs text-ink-muted">
        {part.toolName === 'web_search' ? (
          <Globe className="size-3.5" />
        ) : (
          <Loader2 className="size-3.5 animate-spin" />
        )}
        {part.toolName === 'web_search' ? 'Searching the web…' : 'Working…'}
      </p>
    )
  }
  const change = changesIn({ id: '', role: 'assistant', parts: [part] }).at(0)
  if (!change) return null
  const isUndone = undone.has(change.undo)
  return (
    <div className="flex min-h-[36px] items-center gap-2 rounded-lg bg-cream px-3 text-xs">
      <span
        className={cn(
          'min-w-0 flex-1',
          isUndone && 'text-ink-muted line-through',
        )}
      >
        {change.done}
      </span>
      {!isUndone && (
        <button
          type="button"
          onClick={() => onUndo(change)}
          className="-mr-2 flex min-h-[36px] items-center gap-1 px-2 font-semibold text-ink-soft hover:text-ink"
        >
          <RotateCcw className="size-3.5" />
          Undo
        </button>
      )}
    </div>
  )
}
