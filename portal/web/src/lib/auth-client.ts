/**
 * better-auth client.
 *
 * Same-origin: nginx serves this bundle and proxies /api/auth to the API, so a relative baseURL
 * keeps the build portable between environments — the same reason lib/api.ts uses a relative base.
 *
 * The organization plugin is loaded because a tenant IS an organization here: every API request
 * is scoped by `session.activeOrganizationId`, and `requireTenant` on the server refuses to run a
 * query without one. Setting the active organization after sign-in is therefore not optional
 * polish — without it every page returns 403.
 */
import { createAuthClient } from "better-auth/react";
import { organizationClient } from "better-auth/client/plugins";

export const authClient = createAuthClient({
  baseURL: window.location.origin,
  basePath: "/api/auth",
  plugins: [organizationClient()],
});

export const { signIn, signOut, useSession } = authClient;

/**
 * Ensures the session has an active organization, and reports whether one could be set.
 *
 * `organizationLimit: 1` on the server means a user has at most one, so there is nothing to
 * choose between — asking would be a pointless click. Called after sign-in and on entry to the
 * app layout, because a session restored from a cookie on a fresh page load has no active
 * organization set.
 *
 * Returns false when the user belongs to none. That is a real state, not an error: the account
 * exists but no operator has run `provision-tenant.ts` for it yet, and the UI says so rather
 * than showing a dashboard that 403s on every panel.
 */
export async function ensureActiveOrganization(): Promise<boolean> {
  const session = await authClient.getSession();
  if (session.data?.session.activeOrganizationId) return true;

  const orgs = await authClient.organization.list();
  const first = orgs.data?.[0];
  if (!first) return false;

  await authClient.organization.setActive({ organizationId: first.id });
  return true;
}
