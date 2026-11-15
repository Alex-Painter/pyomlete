import { describe, expect, it } from 'vitest'
import {
  applyEvent,
  changesIn,
  focusOf,
  fromRequestMessages,
  inputHint,
  linkIn,
  readEvents,
  toRequestMessages,
} from './chef'
import type { ChefMessage } from './chef'

const empty = (): ChefMessage => ({ id: 'r1', role: 'assistant', parts: [] })

function fold(events: Array<Record<string, unknown>>): ChefMessage {
  return events.reduce<ChefMessage>(
    (m, ev) => applyEvent(m, ev as { type: string }),
    empty(),
  )
}

describe('applyEvent', () => {
  it('builds text from its deltas', () => {
    const msg = fold([
      { type: 'text-start', id: 't' },
      { type: 'text-delta', id: 't', delta: 'Added ' },
      { type: 'text-delta', id: 't', delta: 'milk.' },
    ])
    expect(msg.parts).toEqual([{ type: 'text', text: 'Added milk.' }])
  })

  it('follows a tool from its call to its output', () => {
    const msg = fold([
      { type: 'tool-input-start', toolCallId: 'c1', toolName: 'add_item' },
      {
        type: 'tool-input-available',
        toolCallId: 'c1',
        toolName: 'add_item',
        input: { name: 'Milk' },
      },
      {
        type: 'tool-output-available',
        toolCallId: 'c1',
        output: { done: 'Added Milk', undo: 'a1' },
      },
    ])
    expect(msg.parts).toEqual([
      {
        type: 'tool',
        toolCallId: 'c1',
        toolName: 'add_item',
        state: 'done',
        input: { name: 'Milk' },
        output: { done: 'Added Milk', undo: 'a1' },
        providerExecuted: false,
      },
    ])
    expect(changesIn(msg)).toEqual([{ done: 'Added Milk', undo: 'a1' }])
  })

  it('links a change to the recipe or list it made', () => {
    const msg = fold([
      {
        type: 'tool-input-available',
        toolCallId: 'c1',
        toolName: 'create_recipe',
        input: {},
      },
      {
        type: 'tool-output-available',
        toolCallId: 'c1',
        output: {
          done: 'Added Dal to your recipes',
          undo: 'a1',
          recipe_id: 'r9',
        },
      },
      {
        type: 'tool-input-available',
        toolCallId: 'c2',
        toolName: 'create_list',
        input: {},
      },
      {
        type: 'tool-output-available',
        toolCallId: 'c2',
        output: { done: 'Started a list, Weekend', undo: 'a2', list_id: 'l3' },
      },
    ])
    expect(changesIn(msg)).toEqual([
      {
        done: 'Added Dal to your recipes',
        undo: 'a1',
        link: { kind: 'recipe', id: 'r9' },
      },
      {
        done: 'Started a list, Weekend',
        undo: 'a2',
        link: { kind: 'list', id: 'l3' },
      },
    ])
  })

  it('links a recipe that was already saved', () => {
    expect(linkIn({ already_saved: true, recipe_id: 'r1' })).toEqual({
      kind: 'recipe',
      id: 'r1',
    })
    expect(linkIn({ done: 'Renamed the list', undo: 'a' })).toBeUndefined()
    expect(linkIn('No such id')).toBeUndefined()
  })

  it('ignores events it has no use for', () => {
    expect(fold([{ type: 'start-step' }, { type: 'finish' }]).parts).toEqual([])
  })
})

describe('toRequestMessages', () => {
  it('sends finished tools back in the AI SDK shape and leaves out web searches', () => {
    const msg = fold([
      {
        type: 'tool-input-available',
        toolCallId: 'w',
        toolName: 'web_search',
        input: {},
        providerExecuted: true,
      },
      {
        type: 'tool-output-available',
        toolCallId: 'w',
        output: [],
        providerExecuted: true,
      },
      {
        type: 'tool-input-available',
        toolCallId: 'c1',
        toolName: 'get_list',
        input: { list_id: 'x' },
      },
      {
        type: 'tool-output-available',
        toolCallId: 'c1',
        output: { name: 'Weekend' },
      },
      {
        type: 'tool-input-available',
        toolCallId: 'c2',
        toolName: 'add_item',
        input: {},
      },
      { type: 'text-start' },
      { type: 'text-delta', delta: 'Done.' },
    ])
    expect(toRequestMessages([msg])[0].parts).toEqual([
      {
        type: 'tool-get_list',
        toolCallId: 'c1',
        state: 'output-available',
        input: { list_id: 'x' },
        output: { name: 'Weekend' },
      },
      { type: 'text', text: 'Done.' },
    ])
  })
})

describe('readEvents', () => {
  it('reads events split across chunks and stops at DONE', async () => {
    const chunks = [
      'data: {"type":"start"}\n\nda',
      'ta: {"type":"finish"}\n\ndata: [DONE]\n\n',
      'data: {"type":"late"}\n\n',
    ]
    const body = new ReadableStream<Uint8Array>({
      start(c) {
        for (const chunk of chunks) c.enqueue(new TextEncoder().encode(chunk))
        c.close()
      },
    })
    const seen = []
    for await (const ev of readEvents(body)) seen.push(ev.type)
    expect(seen).toEqual(['start', 'finish'])
  })
})

describe('focusOf', () => {
  const id = '6527f1c2a1b2c3d4e5f60718'

  it('reads the recipe from the recipe and cook pages', () => {
    expect(focusOf(`/recipe/${id}`)).toEqual({ kind: 'recipe', id })
    expect(focusOf(`/cook/${id}`)).toEqual({ kind: 'recipe', id })
  })

  it('reads the list from the list and shop pages', () => {
    expect(focusOf(`/list/${id}`)).toEqual({ kind: 'list', id })
    expect(focusOf(`/shop/${id}`)).toEqual({ kind: 'list', id })
  })

  it('names the page when nothing in particular is open', () => {
    expect(focusOf('/')).toEqual({ kind: 'page', name: 'Home' })
    expect(focusOf('/recipes/')).toEqual({ kind: 'page', name: 'Recipes' })
    expect(focusOf('/recipe/not-an-id')).toEqual({
      kind: 'page',
      name: 'Omlete',
    })
  })
})

describe('fromRequestMessages', () => {
  it('reads a kept chat back as the request it was sent as', () => {
    const messages: ChefMessage[] = [
      {
        id: 'u1',
        role: 'user',
        parts: [
          { type: 'text', text: 'Add milk' },
          { type: 'file', mediaType: 'image/png', url: 'data:x' },
        ],
      },
      {
        id: 'a1',
        role: 'assistant',
        parts: [
          {
            type: 'tool',
            toolCallId: 'c1',
            toolName: 'add_item',
            state: 'done',
            input: { name: 'milk' },
            output: { done: 'Added milk', undo: 'u' },
          },
          { type: 'text', text: 'Added.' },
        ],
      },
    ]
    const sent = toRequestMessages(messages) as Parameters<
      typeof fromRequestMessages
    >[0]
    expect(fromRequestMessages(sent)).toEqual(messages)
  })

  it('shows a photo that was not kept, and leaves it out of the next request', () => {
    const [msg] = fromRequestMessages([
      {
        id: 'u1',
        role: 'user',
        parts: [{ type: 'file', mediaType: 'image/png', url: '' }],
      },
    ])
    expect(msg.parts).toEqual([
      { type: 'file', mediaType: 'image/png', url: '' },
    ])
    expect(toRequestMessages([msg])[0].parts).toEqual([])
  })
})

describe('inputHint', () => {
  it('lists plain values and leaves out database ids', () => {
    expect(
      inputHint({
        list_id: '6731f0c2a1b2c3d4e5f60718',
        name: 'Oat milk',
        amount: 2,
      }),
    ).toBe('Oat milk · 2')
  })

  it('joins lists of words and cuts long hints short', () => {
    expect(inputHint({ aisles: ['Fruit', 'Dairy'] })).toBe('Fruit, Dairy')
    expect(inputHint({ description: 'a'.repeat(80) }, 10)).toBe('aaaaaaaaa…')
  })

  it('is empty when there is nothing to show', () => {
    expect(inputHint(undefined)).toBe('')
    expect(inputHint({ recipe_id: '6731f0c2a1b2c3d4e5f60718' })).toBe('')
  })
})
