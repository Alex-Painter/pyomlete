const rawApiUrl = import.meta.env.VITE_API_URL || ""
const apiBase =
  rawApiUrl && !rawApiUrl.startsWith("http")
    ? `https://${rawApiUrl}`
    : rawApiUrl

export function apiFetch(path: string, init?: RequestInit): Promise<Response> {
  return fetch(`${apiBase}${path}`, init);
}
