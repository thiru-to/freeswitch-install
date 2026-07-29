/**
 * Tenant provisioning.
 *
 * Creating a tenant is not just a database row: the SIP domain has to exist in Kamailio's
 * `domain` table before any extension in it can register, and the tenant's settings have to be
 * in Redis before Lua can route a call for it. Doing those in one place is what stops a
 * half-provisioned tenant that looks fine in the portal and fails on the wire.
 *
 * Organizations themselves are created through better-auth (`/api/auth/organization/create`);
 * this attaches the telephony configuration to one.
 */
import { Hono } from "hono";
import { eq } from "drizzle-orm";
import { db } from "../db";
import { tenantSettings } from "../db/schema";
import { recordAudit } from "../lib/audit";
import { rebuildTenant } from "../services/cache";
import { syncDomain, reloadKamailio } from "../services/kamailio-sync";
import { requireTenant, requireRole, type AppEnv } from "../middleware/tenant";

export const tenants = new Hono<AppEnv>();
tenants.use("*", requireTenant);

/** The active tenant's own settings. Any member may read; only admins may change. */
tenants.get("/", async (c) => {
  const row = await db.query.tenantSettings.findFirst({
    where: eq(tenantSettings.organizationId, c.get("organizationId")),
  });
  if (!row) return c.json({ error: "Tenant is not provisioned" }, 404);
  return c.json(row);
});

/**
 * Provisions telephony for the active organization.
 *
 * The SIP domain is the tenancy boundary at the SIP layer, so it is unique across the whole
 * platform - two tenants cannot share one, or `use_domain=1` stops distinguishing them.
 */
tenants.post("/", requireRole("owner", "admin"), async (c) => {
  const organizationId = c.get("organizationId");
  const body = await c.req.json<{
    sipDomain?: string;
    tier?: "shared" | "dedicated";
    maxConcurrentCalls?: number;
    timezone?: string;
    defaultCallerIdName?: string;
    defaultCallerIdNumber?: string;
  }>();

  if (!body.sipDomain) return c.json({ error: "sipDomain is required" }, 400);

  const existing = await db.query.tenantSettings.findFirst({
    where: eq(tenantSettings.sipDomain, body.sipDomain),
  });
  if (existing && existing.organizationId !== organizationId) {
    return c.json({ error: `SIP domain ${body.sipDomain} is already in use` }, 409);
  }

  const values = {
    organizationId,
    sipDomain: body.sipDomain,
    tier: body.tier ?? ("shared" as const),
    // A dedicated tenant gets its own dispatcher set; shared tenants all use set 1. This is
    // what keeps the two commercial tiers as one architecture.
    dispatcherSetId: body.tier === "dedicated" ? 0 : 1,
    maxConcurrentCalls: body.maxConcurrentCalls ?? 10,
    timezone: body.timezone ?? "Etc/UTC",
    defaultCallerIdName: body.defaultCallerIdName ?? null,
    defaultCallerIdNumber: body.defaultCallerIdNumber ?? null,
  };

  const [row] = await db
    .insert(tenantSettings)
    .values(values)
    .onConflictDoUpdate({ target: tenantSettings.organizationId, set: values })
    .returning();
  if (!row) return c.json({ error: "Provisioning failed" }, 500);

  if (row.dispatcherSetId === 0) {
    return c.json(
      {
        error: "Dedicated tier needs a dispatcher set assigned",
        detail: "Allocate a set id and PATCH dispatcherSetId before routing calls",
        tenant: row,
      },
      202,
    );
  }

  // Kamailio must know the domain before anyone can register into it.
  await syncDomain(row.sipDomain);
  await reloadKamailio();
  await rebuildTenant(organizationId);

  await recordAudit(c, {
    action: existing ? "update" : "create",
    entityType: "tenant_settings",
    entityId: organizationId,
    before: existing,
    after: row,
  });

  return c.json(row, existing ? 200 : 201);
});

/**
 * Forces a full cache rebuild for this tenant. The repair action when Redis is suspected
 * stale - after a flush, a restore, or a manual database edit.
 */
tenants.post("/rebuild-cache", requireRole("owner", "admin"), async (c) => {
  const organizationId = c.get("organizationId");
  await rebuildTenant(organizationId);
  await recordAudit(c, {
    action: "rebuild-cache",
    entityType: "tenant_settings",
    entityId: organizationId,
  });
  return c.json({ status: "rebuilt" });
});
