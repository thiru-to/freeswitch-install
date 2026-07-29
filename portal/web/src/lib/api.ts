/**
 * API client.
 *
 * Same-origin: nginx serves this bundle and proxies /api to the Hono API on loopback, so a
 * relative base keeps the build portable between environments - no rebuild to change hostname.
 */

const BASE = import.meta.env.VITE_API_BASE ?? "/api";

/**
 * Fields are declared explicitly rather than using constructor parameter properties: the app
 * tsconfig sets `erasableSyntaxOnly`, which disallows syntax that needs a runtime transform.
 */
export class ApiError extends Error {
  status: number;
  detail?: string;

  constructor(status: number, message: string, detail?: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.detail = detail;
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    ...init,
    // Session cookie must travel; better-auth is cookie-based.
    credentials: "include",
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
  });

  if (!res.ok) {
    let message = res.statusText;
    let detail: string | undefined;
    try {
      const body = (await res.json()) as { error?: string; detail?: string };
      message = body.error ?? message;
      detail = body.detail;
    } catch {
      /* non-JSON error body */
    }
    throw new ApiError(res.status, message, detail);
  }

  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

export const api = {
  get: <T>(path: string) => request<T>(path),
  post: <T>(path: string, body?: unknown) =>
    request<T>(path, { method: "POST", body: body ? JSON.stringify(body) : undefined }),
  patch: <T>(path: string, body: unknown) =>
    request<T>(path, { method: "PATCH", body: JSON.stringify(body) }),
  delete: <T>(path: string) => request<T>(path, { method: "DELETE" }),
};

/* ---------------------------------------------------------------------------------------
 * Types mirroring the API. Kept hand-written rather than generated: the surface is small and
 * a generator is another build step to keep working.
 * ------------------------------------------------------------------------------------ */

export type Extension = {
  id: string;
  organizationId: string;
  number: string;
  displayName: string;
  voicemailEnabled: boolean;
  voicemailEmail: string | null;
  callerIdName: string | null;
  callerIdNumber: string | null;
  codecPrefs: string | null;
  maxConcurrentCalls: number | null;
  deviceMac: string | null;
  enabled: boolean;
  createdAt: string;
  updatedAt: string;
  /** Returned only on create - the plaintext is not recoverable afterwards. */
  sipPassword?: string;
};

export type TenantSettings = {
  organizationId: string;
  sipDomain: string;
  tier: "shared" | "dedicated";
  dispatcherSetId: number;
  egressMode: "direct" | "proxied";
  stirShakenEnabled: boolean;
  maxConcurrentCalls: number;
  recordingPolicy: "none" | "inbound" | "outbound" | "all";
  timezone: string;
  defaultCallerIdName: string | null;
  defaultCallerIdNumber: string | null;
  enabled: boolean;
};

export type Health = {
  status: "ok" | "degraded";
  database: boolean;
  redis: boolean;
  freeswitch: boolean;
};

export const endpoints = {
  health: () => api.get<Health>("/../health"),
  tenant: () => api.get<TenantSettings>("/tenant"),
  extensions: () => api.get<Extension[]>("/extensions"),
  extension: (id: string) => api.get<Extension>(`/extensions/${id}`),
  createExtension: (body: Partial<Extension> & { number: string; displayName: string }) =>
    api.post<Extension>("/extensions", body),
  updateExtension: (id: string, body: Partial<Extension>) =>
    api.patch<Extension>(`/extensions/${id}`, body),
  deleteExtension: (id: string) => api.delete<void>(`/extensions/${id}`),
};
