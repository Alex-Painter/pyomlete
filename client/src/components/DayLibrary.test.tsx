// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { DndContext, MouseSensor, useSensor, useSensors } from '@dnd-kit/core'
import type { ReactNode } from 'react'
import type { RecipeSummary } from '@/lib/types'
import { DayLibrary } from './DayLibrary'

vi.mock('@tanstack/react-router', () => ({
  Link: ({ children }: { children: ReactNode }) => <a>{children}</a>,
}))

const soup = {
  id: 'r1',
  title: 'Soup',
  image_url: null,
  total_minutes: null,
  rating: null,
} as unknown as RecipeSummary

function Library({ onPick }: { onPick: (r: RecipeSummary) => void }) {
  // As on Plan: a drag starts once the mouse has moved 6px.
  const sensors = useSensors(useSensor(MouseSensor, { activationConstraint: { distance: 6 } }))
  return (
    <DndContext sensors={sensors}>
      <DayLibrary
        id="lib"
        heading="Pick"
        recipes={[soup]}
        isLoading={false}
        days={[]}
        today="2026-10-11"
        markFor={() => 'add'}
        onPick={onPick}
        draggable
      />
    </DndContext>
  )
}

describe('DayLibrary', () => {
  afterEach(cleanup)

  const row = () => screen.getByRole('button', { name: /Soup/ })

  it('a tap picks the meal', () => {
    const onPick = vi.fn()
    render(<Library onPick={onPick} />)
    fireEvent.click(row())
    expect(onPick).toHaveBeenCalledWith(soup)
  })

  it('releasing over the row after Escape cancelled its drag does not pick it', async () => {
    const onPick = vi.fn()
    render(<Library onPick={onPick} />)
    fireEvent.pointerDown(row())
    fireEvent.mouseDown(row(), { button: 0, clientX: 10, clientY: 10 })
    fireEvent.mouseMove(document, { clientX: 10, clientY: 60 })
    expect(row().closest('li')?.className).toContain('opacity-40')
    fireEvent.keyDown(document, { key: 'Escape', code: 'Escape' })
    expect(row().closest('li')?.className).not.toContain('opacity-40')
    // dnd-kit's own guard lifts 50ms after the drag ends.
    await new Promise((r) => setTimeout(r, 80))
    fireEvent.mouseUp(row())
    fireEvent.click(row())
    expect(onPick).not.toHaveBeenCalled()

    // The next tap is a tap again.
    fireEvent.pointerDown(row())
    fireEvent.click(row())
    expect(onPick).toHaveBeenCalledWith(soup)
  })
})
