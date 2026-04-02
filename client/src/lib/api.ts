const apiBase = import.meta.env.VITE_API_URL || "";

export function apiFetch(path: string, init?: RequestInit): Promise<Response> {
  return fetch(`${apiBase}${path}`, init);
}
