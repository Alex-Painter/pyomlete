const rawApiUrl = import.meta.env.VITE_API_URL || ""
const apiBase =
  rawApiUrl && !rawApiUrl.startsWith("http")
    ? `https://${rawApiUrl}`
    : rawApiUrl

export function apiFetch(path: string, init?: RequestInit): Promise<Response> {
  return fetch(`${apiBase}${path}`, init);
}

/** An HTTP error carrying the status and FastAPI's `detail` payload. */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly detail: unknown,
  ) {
    super(typeof detail === "string" ? detail : `Request failed (${status})`);
    this.name = "ApiError";
  }
}

/**
 * `apiFetch` that rejects on a non-2xx instead of handing back an error body
 * for the caller to render as if it were data. `fetch` only rejects on a
 * network failure, so callers using it directly treat a 502 as success.
 */
export async function apiJson<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await apiFetch(path, init);

  if (!res.ok) {
    let detail: unknown = null;
    try {
      detail = ((await res.json()) as { detail?: unknown }).detail ?? null;
    } catch {
      // A proxy or gateway error won't be JSON. The status still tells us
      // enough to show something useful.
    }
    throw new ApiError(res.status, detail);
  }

  return res.json() as Promise<T>;
}
