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

  /* A 2xx that is not JSON means something other than the API answered - nginx serving the SPA
     fallback for a mistyped path, a captive portal, a proxy error page. Letting res.json()
     throw surfaces "Unexpected token '<'" to an operator, which describes the symptom and
     hides the cause. */
  const contentType = res.headers.get("Content-Type") ?? "";
  if (!contentType.includes("json")) {
    throw new ApiError(
      res.status,
      "The API did not answer",
      `${path} returned ${contentType || "an unknown content type"} instead of JSON. ` +
        `Check that nginx is proxying /api to the API service.`,
    );
  }

  try {
    return (await res.json()) as T;
  } catch {
    throw new ApiError(res.status, "The API returned malformed JSON", path);
  }
}

export const api = {
  get: <T>(path: string) => request<T>(path),
  post: <T>(path: string, body?: unknown) =>
    request<T>(path, { method: "POST", body: body ? JSON.stringify(body) : undefined }),
  put: <T>(path: string, body?: unknown) =>
    request<T>(path, { method: "PUT", body: body ? JSON.stringify(body) : undefined }),
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
  /** Returned on create, and on the patch that resets it. Same deal. */
  voicemailPin?: string;
};

/**
 * The polymorphic destination that inbound routes, IVR options, ring-group failover and both
 * branches of a time condition all point at. `external` carries a literal number in the id;
 * `hangup` carries nothing.
 */
export type DestinationType =
  | "extension"
  | "ring_group"
  | "ivr"
  | "time_condition"
  | "queue"
  | "voicemail"
  | "fax"
  | "external"
  | "hangup";

/** Types whose id names a row we own, as opposed to a literal or nothing. */
export const DESTINATION_NEEDS_ROW: DestinationType[] = [
  "extension", "ring_group", "ivr", "time_condition", "queue",
];

export type Trunk = {
  id: string;
  organizationId: string | null;
  name: string;
  authMode: "ip" | "register";
  host: string;
  port: number | null;
  transport: string | null;
  username: string | null;
  fromDomain: string | null;
  codecPrefs: string | null;
  priority: number;
  carrierSigns: boolean;
  enabled: boolean;
};

export type InboundRoute = {
  id: string;
  didPattern: string;
  description: string | null;
  destinationType: DestinationType | null;
  destinationId: string | null;
  priority: number;
  enabled: boolean;
};

export type OutboundRoute = {
  id: string;
  name: string;
  pattern: string;
  trunkId: string | null;
  stripDigits: number | null;
  prependDigits: string | null;
  callerIdOverride: string | null;
  priority: number;
  isEmergency: boolean;
  enabled: boolean;
};

export type RingGroup = {
  id: string;
  number: string;
  name: string;
  strategy: "simultaneous" | "sequential";
  ringTimeoutSec: number;
  failoverType: DestinationType | null;
  failoverId: string | null;
  enabled: boolean;
};

export type RingGroupMember = {
  id: string;
  extensionId: string;
  number: string;
  displayName: string;
  position: number;
  delaySec: number;
};

export type IvrMenu = {
  id: string;
  number: string;
  name: string;
  greetingSound: string | null;
  invalidSound: string | null;
  timeoutSec: number;
  maxRetries: number;
  timeoutType: DestinationType | null;
  timeoutId: string | null;
  enabled: boolean;
};

export type IvrOption = {
  id: string;
  ivrMenuId: string;
  digit: string;
  destinationType: DestinationType;
  destinationId: string | null;
  description: string | null;
};

export type TimeConditionRule = {
  days?: number[];
  start?: string;
  end?: string;
  date?: string;
  invert?: boolean;
};

export type TimeCondition = {
  id: string;
  name: string;
  timezone: string;
  rules: TimeConditionRule[];
  matchType: DestinationType | null;
  matchId: string | null;
  noMatchType: DestinationType | null;
  noMatchId: string | null;
  enabled: boolean;
};

export type Cdr = {
  id: string;
  callUuid: string;
  direction: "inbound" | "outbound" | "internal";
  callerNumber: string | null;
  callerName: string | null;
  destinationNumber: string;
  startedAt: string;
  answeredAt: string | null;
  endedAt: string | null;
  durationSec: number;
  billsecSec: number;
  hangupCause: string | null;
  attestation: string | null;
  extensionNumber: string | null;
  extensionName: string | null;
  trunkName: string | null;
};

export type CdrPage = { rows: Cdr[]; total: number; limit: number; offset: number };

export type CdrSummary = {
  calls: number;
  answered: number;
  answerRate: number | null;
  inbound: number;
  outbound: number;
  internal: number;
  billableSec: number;
};

export type CdrFilters = {
  direction?: string;
  number?: string;
  extensionId?: string;
  answered?: string;
  from?: string;
  to?: string;
  limit?: number;
  offset?: number;
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

  trunks: () => api.get<Trunk[]>("/trunks"),
  createTrunk: (body: Partial<Trunk>) => api.post<Trunk>("/trunks", body),
  updateTrunk: (id: string, body: Partial<Trunk>) => api.patch<Trunk>(`/trunks/${id}`, body),
  deleteTrunk: (id: string) => api.delete<void>(`/trunks/${id}`),
  /** Separate endpoint so the plaintext never appears in a patch body or an audit diff. */
  setTrunkPassword: (id: string, password: string) =>
    api.put<void>(`/trunks/${id}/password`, { password }),

  inboundRoutes: () => api.get<InboundRoute[]>("/inbound-routes"),
  createInboundRoute: (body: Partial<InboundRoute>) =>
    api.post<InboundRoute>("/inbound-routes", body),
  updateInboundRoute: (id: string, body: Partial<InboundRoute>) =>
    api.patch<InboundRoute>(`/inbound-routes/${id}`, body),
  deleteInboundRoute: (id: string) => api.delete<void>(`/inbound-routes/${id}`),

  outboundRoutes: () => api.get<OutboundRoute[]>("/outbound-routes"),
  createOutboundRoute: (body: Partial<OutboundRoute>) =>
    api.post<OutboundRoute>("/outbound-routes", body),
  updateOutboundRoute: (id: string, body: Partial<OutboundRoute>) =>
    api.patch<OutboundRoute>(`/outbound-routes/${id}`, body),
  deleteOutboundRoute: (id: string) => api.delete<void>(`/outbound-routes/${id}`),

  ringGroups: () => api.get<RingGroup[]>("/ring-groups"),
  createRingGroup: (body: Partial<RingGroup>) => api.post<RingGroup>("/ring-groups", body),
  updateRingGroup: (id: string, body: Partial<RingGroup>) =>
    api.patch<RingGroup>(`/ring-groups/${id}`, body),
  deleteRingGroup: (id: string) => api.delete<void>(`/ring-groups/${id}`),
  ringGroupMembers: (id: string) => api.get<RingGroupMember[]>(`/ring-groups/${id}/members`),
  addRingGroupMember: (id: string, body: { extensionId: string; delaySec?: number }) =>
    api.post<RingGroupMember>(`/ring-groups/${id}/members`, body),
  removeRingGroupMember: (groupId: string, memberId: string) =>
    api.delete<void>(`/ring-groups/${groupId}/members/${memberId}`),

  ivrMenus: () => api.get<IvrMenu[]>("/ivr-menus"),
  createIvrMenu: (body: Partial<IvrMenu>) => api.post<IvrMenu>("/ivr-menus", body),
  updateIvrMenu: (id: string, body: Partial<IvrMenu>) =>
    api.patch<IvrMenu>(`/ivr-menus/${id}`, body),
  deleteIvrMenu: (id: string) => api.delete<void>(`/ivr-menus/${id}`),
  ivrOptions: (id: string) => api.get<IvrOption[]>(`/ivr-menus/${id}/options`),
  setIvrOption: (
    id: string,
    digit: string,
    body: { destinationType: DestinationType; destinationId?: string | null; description?: string },
  ) => api.put<IvrOption>(`/ivr-menus/${id}/options/${digit}`, body),
  deleteIvrOption: (id: string, digit: string) =>
    api.delete<void>(`/ivr-menus/${id}/options/${digit}`),

  timeConditions: () => api.get<TimeCondition[]>("/time-conditions"),
  createTimeCondition: (body: Partial<TimeCondition>) =>
    api.post<TimeCondition>("/time-conditions", body),
  updateTimeCondition: (id: string, body: Partial<TimeCondition>) =>
    api.patch<TimeCondition>(`/time-conditions/${id}`, body),
  deleteTimeCondition: (id: string) => api.delete<void>(`/time-conditions/${id}`),

  cdr: (filters: CdrFilters = {}) => {
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(filters)) {
      if (v !== undefined && v !== null && v !== "") q.set(k, String(v));
    }
    const qs = q.toString();
    return api.get<CdrPage>(`/cdr${qs ? `?${qs}` : ""}`);
  },
  cdrSummary: (from?: string, to?: string) => {
    const q = new URLSearchParams();
    if (from) q.set("from", from);
    if (to) q.set("to", to);
    const qs = q.toString();
    return api.get<CdrSummary>(`/cdr/summary${qs ? `?${qs}` : ""}`);
  },
};
