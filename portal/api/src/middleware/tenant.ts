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
import { and, eq } from "drizzle-orm";
import { auth, ROLES, type RoleName } from "../auth";
import { db } from "../db";
import { member } from "../db/schema";

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

  /**
   * The role comes from the membership row, not the session.
   *
   * This used to read `session.activeOrganizationRole` with a fallback of `"member"`. That field
   * does not exist on a better-auth session, so the fallback fired every time and EVERY user in
   * every organization was treated as a `member` - the role column was never consulted at all.
   * A `viewer` had a member's create and delete rights on extensions and call flows.
   *
   * Reading the row also re-verifies the membership on every request, which the session alone
   * cannot do: `activeOrganizationId` is copied into the session at set-active time, so removing
   * someone from an organization left their existing session fully functional until it expired -
   * up to eight hours of access after being revoked.
   *
   * One indexed lookup on (user_id, organization_id). Worth it for a check that decides what a
   * request may do.
   */
  const [membership] = await db
    .select({ role: member.role })
    .from(member)
    .where(and(eq(member.userId, session.user.id), eq(member.organizationId, organizationId)))
    .limit(1);

  if (!membership) {
    // Fail closed. A session naming an organization the user is not in is either a revoked
    // membership or a forged claim; neither should reach a query.
    return c.json({ error: "Not a member of the active organization" }, 403);
  }

  c.set("userId", session.user.id);
  c.set("organizationId", organizationId);
  c.set("role", membership.role);

  await next();
});

/**
 * Coarse role gate, for "these named roles only" on a whole route group.
 *
 * Prefer `requirePermission` below - it consults the access-control statement in auth.ts rather
 * than hard-coding a role list, so adding a role does not mean auditing every route.
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

/**
 * Checks the caller's role against the access-control statement defined in auth.ts.
 *
 * This is the enforcement half of a model that was, for a while, purely declarative: auth.ts
 * described four roles in detail - including the reasoning for withholding trunk credentials and
 * CDR export from a general admin - and nothing ever consulted it. A `viewer`, whose documented
 * purpose is "diagnose without being able to change routing", could create trunks, set carrier
 * credentials, and delete extensions.
 *
 * Resolved locally from the role already on the session, so it costs no round trip.
 */
export function requirePermission(resource: string, ...actions: string[]) {
  return createMiddleware<AppEnv>(async (c, next) => {
    const role = c.get("role");
    const definition = ROLES[role as RoleName];

    /* An unknown role is refused rather than defaulted. Defaulting would mean a typo in a
       member row, or a role added to better-auth but not here, silently granting access. */
    if (!definition) {
      return c.json({ error: "Unrecognised role", actual: role }, 403);
    }

    const decision = definition.authorize({ [resource]: actions });
    if (!decision.success) {
      return c.json(
        { error: "Insufficient permissions", required: `${resource}:${actions.join(",")}`, actual: role },
        403,
      );
    }
    await next();
  });
}

/** Maps an HTTP method onto the action name used in the access-control statement. */
export function actionForMethod(method: string): string {
  switch (method.toUpperCase()) {
    case "GET":
    case "HEAD":
      return "read";
    case "POST":
      return "create";
    case "PUT":
    case "PATCH":
      return "update";
    case "DELETE":
      return "delete";
    default:
      // Anything unmapped is refused by requirePermission, since no statement grants it.
      return "unknown";
  }
}
