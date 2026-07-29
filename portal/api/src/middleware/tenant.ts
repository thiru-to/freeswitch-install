/**
 * Tenant scoping.
 *
 * This is the isolation boundary. The plan chose API-layer enforcement over Postgres RLS
 * because the API is the only writer - which means this middleware is load-bearing, not
 * convenience. Every route that touches tenant data mounts it, and every query filters on the
 * `organizationId` it puts on the context.
 *
 * The failure mode being defended against is a route that forgets to filter and quietly
 * returns another tenant's extensions. `requireTenant` refuses to proceed without an active
 * organization rather than defaulting to "all", so forgetting produces an error, not a leak.
 */
import type { Context, Next } from "hono";
import { createMiddleware } from "hono/factory";
import { auth } from "../auth";

export type TenantVars = {
  userId: string;
  organizationId: string;
  role: string;
};

export type AppEnv = { Variables: TenantVars };

/**
 * Resolves the session and its active organization. Rejects rather than falling back, because
 * an unscoped query in a multi-tenant system is a data breach, not a bug.
 */
export const requireTenant = createMiddleware<AppEnv>(async (c: Context, next: Next) => {
  const session = await auth.api.getSession({ headers: c.req.raw.headers });

  if (!session?.user) {
    return c.json({ error: "Not authenticated" }, 401);
  }

  const organizationId = session.session.activeOrganizationId;
  if (!organizationId) {
    // A user with no active organization is a real state - they belong to none yet, or have
    // not selected one. Say so precisely so the portal can prompt rather than guess.
    return c.json(
      {
        error: "No active organization",
        detail: "Select an organization with POST /api/auth/organization/set-active",
      },
      403,
    );
  }

  c.set("userId", session.user.id);
  c.set("organizationId", organizationId);
  c.set("role", (session.session as { activeOrganizationRole?: string }).activeOrganizationRole ?? "member");

  await next();
});

/**
 * Coarse role gate. Fine-grained permission checks use better-auth's access control; this is
 * for the common "admins only" case on a whole route group.
 */
export function requireRole(...allowed: string[]) {
  return createMiddleware<AppEnv>(async (c, next) => {
    const role = c.get("role");
    if (!allowed.includes(role)) {
      return c.json({ error: "Insufficient permissions", required: allowed, actual: role }, 403);
    }
    await next();
  });
}
