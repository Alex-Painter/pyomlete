import { useEffect, useState } from 'react'
import { Minus, Plus, Trash2 } from 'lucide-react'
import { BottomSheet } from '@/components/BottomSheet'
import { Button } from '@/components/ui/button'
import type { ListItem } from '@/lib/types'
import { cn } from '@/lib/utils'

const COMMON_UNITS = ['g', 'kg', 'ml', 'l', 'pack', 'tin', 'bunch', 'whole']
const SPELLED_OUT = new Set(['gram', 'grams', 'kilograms', 'millilitres', 'milliliters', 'litres', 'liters'])

function stepFor(unit: string | null): number {
  if (unit === 'g' || unit === 'ml' || unit === 'grams') return 50
  if (unit === 'kg' || unit === 'l') return 0.5
  return 1
}

/**
 * Edit one item in a sheet: name, a quantity stepper, unit chips and category
 * chips. Replaces the old inline form that pushed the rows below it around.
 * Mirrors a SwiftUI form sheet: `item`, `onSave(updates)`, `onDelete`.
 */
export function ItemSheet({
  item,
  open,
  onOpenChange,
  categories,
  units = [],
  onSave,
  onDelete,
}: {
  item: ListItem | null
  open: boolean
  onOpenChange: (open: boolean) => void
  categories: string[]
  units?: string[]
  onSave: (updates: Partial<ListItem>) => void
  onDelete: () => void
}) {
  const [name, setName] = useState('')
  const [amount, setAmount] = useState('')
  const [unit, setUnit] = useState<string | null>(null)
  const [category, setCategory] = useState('')

  useEffect(() => {
    if (!item) return
    setName(item.name)
    setAmount(item.amount == null ? '' : String(item.amount))
    setUnit(item.unit || null)
    setCategory(item.category)
  }, [item])

  if (!item) return null

  const unitChoices = Array.from(
    new Set([
      ...COMMON_UNITS,
      // Recipe units that just spell out a common one ("grams") add nothing.
      ...units.filter((u) => u.length <= 12 && !SPELLED_OUT.has(u.toLowerCase())).slice(0, 8),
      ...(unit ? [unit] : []),
    ]),
  )

  const numeric = amount.trim() === '' ? null : Number(amount)
  const step = stepFor(unit)
  const bump = (dir: 1 | -1) => {
    const next = Math.max(0, (numeric ?? 0) + dir * step)
    setAmount(next === 0 ? '' : String(Math.round(next * 100) / 100))
  }

  const save = () => {
    const updates: Partial<ListItem> = {}
    const trimmed = name.trim()
    if (trimmed && trimmed !== item.name) updates.name = trimmed
    const nextAmount = numeric != null && Number.isFinite(numeric) ? numeric : null
    if (nextAmount !== item.amount) updates.amount = nextAmount
    if ((unit || null) !== (item.unit || null)) updates.unit = unit
    if (category !== item.category) updates.category = category
    if (Object.keys(updates).length > 0) onSave(updates)
    onOpenChange(false)
  }

  return (
    <BottomSheet
      open={open}
      onOpenChange={onOpenChange}
      title="Edit item"
      height="half"
      footer={
        <div className="flex items-center gap-3">
          <Button
            variant="ghost"
            onClick={() => {
              onOpenChange(false)
              onDelete()
            }}
            className="min-h-[44px] text-danger hover:bg-red-50 hover:text-danger"
          >
            <Trash2 className="size-4" />
            Delete
          </Button>
          <div className="flex-1" />
          <Button onClick={save} className="min-h-[44px] px-6 font-semibold">
            Done
          </Button>
        </div>
      }
    >
      <form
        onSubmit={(e) => {
          e.preventDefault()
          save()
        }}
        className="space-y-5"
      >
        <label className="block space-y-1.5">
          <span className="text-sm font-medium text-ink-soft">Name</span>
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="h-12 w-full rounded-xl border border-line bg-cream px-3 text-base outline-none focus:ring-2 focus:ring-ring"
          />
        </label>

        <div className="space-y-1.5">
          <span className="text-sm font-medium text-ink-soft">Quantity</span>
          <div className="flex items-center gap-2">
            <button
              type="button"
              aria-label="Less"
              onClick={() => bump(-1)}
              className="flex size-12 items-center justify-center rounded-xl border border-line bg-white hover:bg-sand"
            >
              <Minus className="size-5" />
            </button>
            <input
              inputMode="decimal"
              aria-label="Amount"
              value={amount}
              onChange={(e) => {
                const v = e.target.value
                if (v === '' || /^\d*\.?\d*$/.test(v)) setAmount(v)
              }}
              placeholder="—"
              className="h-12 w-24 rounded-xl border border-line bg-cream text-center text-lg tabular-nums outline-none focus:ring-2 focus:ring-ring"
            />
            <button
              type="button"
              aria-label="More"
              onClick={() => bump(1)}
              className="flex size-12 items-center justify-center rounded-xl border border-line bg-white hover:bg-sand"
            >
              <Plus className="size-5" />
            </button>
          </div>
        </div>

        <ChipGroup
          label="Unit"
          options={['No unit', ...unitChoices]}
          value={unit ?? 'No unit'}
          onChange={(v) => setUnit(v === 'No unit' ? null : v)}
        />

        <ChipGroup label="Aisle" options={categories} value={category} onChange={setCategory} />
        <button type="submit" className="hidden" />
      </form>
    </BottomSheet>
  )
}

function ChipGroup({
  label,
  options,
  value,
  onChange,
}: {
  label: string
  options: string[]
  value: string
  onChange: (v: string) => void
}) {
  return (
    <fieldset className="space-y-1.5">
      <legend className="mb-1.5 text-sm font-medium text-ink-soft">{label}</legend>
      <div className="flex flex-wrap gap-2">
        {options.map((o) => (
          <button
            key={o}
            type="button"
            aria-pressed={o === value}
            onClick={() => onChange(o)}
            className={cn(
              'min-h-[40px] rounded-full border px-3.5 text-sm transition-colors',
              o === value
                ? 'border-ink bg-ink text-white'
                : 'border-line bg-white text-ink-soft hover:bg-sand',
            )}
          >
            {o}
          </button>
        ))}
      </div>
    </fieldset>
  )
}
