/**
 * Talking to Chef: the chat request, the reply as it streams in, and Undo.
 *
 * The server speaks the AI SDK's UI message stream (`POST /api/chef/chat`).
 * Reading it here takes a few dozen lines, so the app carries no chat library
 * for it. Each change Chef makes arrives as a tool output with an `undo` id,
 * which `POST /api/chef/actions/{id}/undo` puts back.
 */
import { apiFetch, apiJson } from './api'

export type ChefPart =
  | { type: 'text'; text: string }
  | { type: 'file'; mediaType: string; url: string }
  | {
      type: 'tool'
      toolCallId: string
      toolName: string
      state: 'running' | 'done' | 'error'
      input?: unknown
      output?: unknown
      /** Run by Anthropic (web search), not by our server. */
      providerExecuted?: boolean
    }

export type ChefMessage = {
  id: string
  role: 'user' | 'assistant'
  parts: ChefPart[]
}

/** A change Chef made, with the id that undoes it. */
export type ChefChange = { done: string; undo: string }

type StreamEvent = { type: string; [key: string]: unknown }

/**
 * What Chef is looking at: the recipe or list on screen, or else the page.
 * Matches the ids `server/chef/chat.py` reads from the same path.
 */
export type ChefFocus =
  | { kind: 'recipe'; id: string }
  | { kind: 'list'; id: string }
  | { kind: 'page'; name: string }

const PAGE_NAMES: Record<string, string> = {
  '/': 'Home',
  '/discover': 'Discover',
  '/recipes': 'Recipes',
  '/create': 'New recipe',
  '/settings': 'Settings',
}

export function focusOf(path: string): ChefFocus {
  const item = /^\/(list|shop|recipe|cook)\/([0-9a-f]{24})/.exec(path)
  if (item) {
    const kind = item[1] === 'list' || item[1] === 'shop' ? 'list' : 'recipe'
    return { kind, id: item[2] }
  }
  return {
    kind: 'page',
    name: PAGE_NAMES[path.replace(/(.)\/$/, '$1')] ?? 'Omlete',
  }
}

export function newChatId(): string {
  return crypto.randomUUID()
}

/** Fold one stream event into the reply being built. */
export function applyEvent(msg: ChefMessage, ev: StreamEvent): ChefMessage {
  const parts = [...msg.parts]
  const toolAt = (id: unknown) =>
    parts.findIndex((p) => p.type === 'tool' && p.toolCallId === id)
  switch (ev.type) {
    case 'text-start':
      parts.push({ type: 'text', text: '' })
      break
    case 'text-delta': {
      let i = parts.map((p) => p.type).lastIndexOf('text')
      if (i < 0) i = parts.push({ type: 'text', text: '' }) - 1
      const part = parts[i] as { type: 'text'; text: string }
      parts[i] = { ...part, text: part.text + String(ev.delta ?? '') }
      break
    }
    case 'tool-input-start':
    case 'tool-input-available': {
      const i = toolAt(ev.toolCallId)
      const next = {
        type: 'tool' as const,
        toolCallId: String(ev.toolCallId),
        toolName: String(ev.toolName),
        state: 'running' as const,
        input: ev.input,
        providerExecuted: Boolean(ev.providerExecuted),
      }
      if (i < 0) parts.push(next)
      else
        parts[i] = {
          ...(parts[i] as typeof next),
          input: ev.input ?? (parts[i] as typeof next).input,
        }
      break
    }
    case 'tool-output-available':
    case 'tool-output-error': {
      const i = toolAt(ev.toolCallId)
      if (i >= 0) {
        const part = parts[i] as Extract<ChefPart, { type: 'tool' }>
        parts[i] =
          ev.type === 'tool-output-available'
            ? { ...part, state: 'done', output: ev.output }
            : { ...part, state: 'error', output: ev.errorText }
      }
      break
    }
  }
  return { ...msg, parts }
}

/** The changes in a reply that can still be undone, oldest first. */
export function changesIn(msg: ChefMessage): ChefChange[] {
  return msg.parts.flatMap((p) => {
    if (p.type !== 'tool' || p.state !== 'done') return []
    const out = p.output as Partial<ChefChange> | null | undefined
    return out && typeof out.undo === 'string' && typeof out.done === 'string'
      ? [{ done: out.done, undo: out.undo }]
      : []
  })
}

/**
 * The conversation as the server reads it. Web searches are left out: their
 * results belong to Anthropic's side of the turn, and Chef's text already
 * says what it found.
 */
export function toRequestMessages(messages: ChefMessage[]) {
  return messages.map((m) => ({
    id: m.id,
    role: m.role,
    parts: m.parts.flatMap((p): object[] => {
      if (p.type === 'text') return p.text ? [p] : []
      if (p.type === 'file') return [p]
      if (p.providerExecuted || p.state !== 'done') return []
      return [
        {
          type: `tool-${p.toolName}`,
          toolCallId: p.toolCallId,
          state: 'output-available',
          input: p.input ?? {},
          output: p.output,
        },
      ]
    }),
  }))
}

/** The events in a server-sent event stream, as they arrive. */
export async function* readEvents(
  body: ReadableStream<Uint8Array>,
): AsyncGenerator<StreamEvent> {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  for (;;) {
    const { value, done } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })
    let end: number
    while ((end = buffer.indexOf('\n\n')) >= 0) {
      const chunk = buffer.slice(0, end)
      buffer = buffer.slice(end + 2)
      for (const line of chunk.split('\n')) {
        if (!line.startsWith('data: ')) continue
        const data = line.slice(6)
        if (data === '[DONE]') return
        yield JSON.parse(data) as StreamEvent
      }
    }
  }
}

export class ChefError extends Error {}

/**
 * Send the conversation and build Chef's reply. `onReply` gets the reply each
 * time it grows; the finished reply is returned.
 */
export async function askChef({
  chatId,
  messages,
  path,
  signal,
  onReply,
}: {
  chatId: string
  messages: ChefMessage[]
  path: string
  signal?: AbortSignal
  onReply: (reply: ChefMessage) => void
}): Promise<ChefMessage> {
  const res = await apiFetch('/api/chef/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      trigger: 'submit-message',
      id: chatId,
      messages: toRequestMessages(messages),
      page: { path },
    }),
    signal,
  })
  if (!res.ok || !res.body)
    throw new ChefError(`Chef couldn't answer (${res.status})`)

  let reply: ChefMessage = {
    id: crypto.randomUUID(),
    role: 'assistant',
    parts: [],
  }
  for await (const ev of readEvents(res.body)) {
    if (ev.type === 'error')
      throw new ChefError(String(ev.errorText ?? 'Chef ran into a problem'))
    if (ev.type === 'start' && typeof ev.messageId === 'string')
      reply = { ...reply, id: ev.messageId }
    reply = applyEvent(reply, ev)
    onReply(reply)
  }
  return reply
}

export function undoChange(id: string) {
  return apiJson<{ id: string; summary: string; undone: boolean }>(
    `/api/chef/actions/${id}/undo`,
    { method: 'POST' },
  )
}
