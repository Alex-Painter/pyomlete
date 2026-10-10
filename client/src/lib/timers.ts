/**
 * Find cooking times in a step so Cook can offer a one-tap timer.
 *
 * "simmer 10–12 mins"  → 12 minutes (the upper bound: it's a "check by" time)
 * "bake for 45 minutes" → 45 minutes
 * "roast 1 hr 20 min"  → 80 minutes
 * "rest for 30 seconds" → 30 seconds
 */
export type DetectedTimer = {
  /** The words as written, for the button label. */
  label: string
  seconds: number
}

const NUM = String.raw`\d+(?:\.\d+)?|½|an?|one|two|three|four|five|ten|fifteen|twenty|thirty`
const WORDS: Record<string, number> = {
  a: 1,
  an: 1,
  one: 1,
  two: 2,
  three: 3,
  four: 4,
  five: 5,
  ten: 10,
  fifteen: 15,
  twenty: 20,
  thirty: 30,
  '½': 0.5,
}

const UNIT = String.raw`(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b`
const RANGE = String.raw`(${NUM})(?:\s*(?:-|–|—|to|or)\s*(${NUM}))?`
const TIMER_RE = new RegExp(
  String.raw`\b${RANGE}\s*${UNIT}(?:\s*(?:and\s*)?(\d+)\s*(minutes?|mins?|m)\b)?`,
  'gi',
)

function toNumber(raw: string): number {
  const lower = raw.toLowerCase()
  return lower in WORDS ? WORDS[lower] : Number(lower)
}

function unitSeconds(unit: string): number {
  const u = unit.toLowerCase()
  if (u.startsWith('h')) return 3600
  if (u.startsWith('s')) return 1
  return 60
}

export function detectTimers(step: string): DetectedTimer[] {
  const found: DetectedTimer[] = []
  for (const m of step.matchAll(TIMER_RE)) {
    const unit = m[3]
    // A bare "m"/"s"/"h" is too easy to mistake ("2 m long"); only take it
    // straight after a number, like "10m".
    if (unit.length === 1 && !/\d[hms]/i.test(m[0])) continue
    const low = toNumber(m[1])
    const high = m[2] ? toNumber(m[2]) : low
    let seconds = Math.max(low, high) * unitSeconds(unit)
    if (m[4]) seconds += Number(m[4]) * unitSeconds(m[5])
    if (!Number.isFinite(seconds) || seconds <= 0 || seconds > 24 * 3600) continue
    found.push({ label: m[0].trim(), seconds: Math.round(seconds) })
  }
  return found
}

export function formatClock(totalSeconds: number): string {
  const s = Math.max(0, Math.round(totalSeconds))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  const pad = (n: number) => String(n).padStart(2, '0')
  return h > 0 ? `${h}:${pad(m)}:${pad(sec)}` : `${m}:${pad(sec)}`
}
