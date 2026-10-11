const URL_IN_TEXT = /https?:\/\/[^\s<>"]+\.[^\s<>"]+/

/**
 * Pull a recipe link out of whatever was typed with it, so "<link> but use
 * quorn mince" imports the page and applies the change in one go.
 * Returns null when there's no link.
 */
export function splitLink(
  text: string,
): { url: string; changes: string } | null {
  const match = URL_IN_TEXT.exec(text)
  if (!match) return null
  // Punctuation that ends a sentence isn't part of the link.
  const url = match[0].replace(/[.,;:!?)\]]+$/, '')
  const changes = (
    text.slice(0, match.index) + text.slice(match.index + url.length)
  )
    .replace(/\n{3,}/g, '\n\n')
    .trim()
    // The full stop that ended the link's sentence, now left on its own.
    .replace(/\s+[.,;:!?]+$/, '')
  return { url, changes }
}
