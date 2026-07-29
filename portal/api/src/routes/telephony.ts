/**
 * Trunks, routes and call-flow objects.
 *
 * All built on lib/crud.ts, so tenant scoping, audit and the after-change hooks are uniform.
 * What differs per resource is only what has to happen *after* a write - which cache to
 * refresh, and whether Kamailio needs to be told.
 */
import { and, eq } from "drizzle-orm";
import { Hono } from "hono";
import { db } from "../db";
import {
  extension,
  queue,
  inboundRoute,
  ivrMenu,
  ivrOption,
  outboundRoute,
  ringGroup,
  ringGroupMember,
  timeCondition,
  trunk,
} from "../db/schema";
import { crudRoutes, tenantOwns } from "../lib/crud";
import { recordAudit } from "../lib/audit";
import { encrypt } from "../lib/crypto";
import { cacheInboundRoutes, cacheRouteTable, rebuildTenant } from "../services/cache";
import { reloadKamailio, removeTrunkAddress, syncTrunkAddress } from "../services/kamailio-sync";
import { requireTenant, type AppEnv } from "../middleware/tenant";

/**
 * Validates a polymorphic destination reference against the tenant.
 *
 * Destinations appear on inbound routes, IVR options, ring-group failover and both branches of
 * a time condition, and every one of them is an id the client supplies. Without this a tenant
 * can point their call flow at another tenant's ring group or IVR.
 *
 * `prevType`/`prevId` are the values already on the row, and passing them is not optional on an
 * update. A PATCH carries only what is changing, so `{destinationId: "<other tenant's id>"}`
 * arrives with no type at all - and checking the body alone reads that as "no destination
 * given" and waves it through. The pair has to be validated as it will exist after the write,
 * not as it appears in the request.
 */
async function badDestination(
  type: unknown,
  id: unknown,
  organizationId: string,
  prevType?: unknown,
  prevId?: unknown,
): Promise<string | null> {
  const effectiveType = type !== undefined ? type : prevType;
  const effectiveId = id !== undefined ? id : prevId;

  if (effectiveType === undefined || effectiveType === null) {
    // An id with nothing to interpret it is not a harmless no-op: it is the shape the
    // cross-tenant write takes, and there is no legitimate request that produces it.
    if (effectiveId !== undefined && effectiveId !== null && effectiveId !== "") {
      return "destinationType is required when destinationId is set";
    }
    return null;
  }

  // These carry no row reference: `external` holds a literal number, the others nothing.
  if (
    effectiveType === "external" || effectiveType === "hangup" ||
    effectiveType === "voicemail" || effectiveType === "fax"
  ) {
    return null;
  }
  if (effectiveId === undefined || effectiveId === null || effectiveId === "") {
    return `destinationId is required when destinationType is ${String(effectiveType)}`;
  }

  const type_ = effectiveType;
  const id_ = effectiveId;

  const owned = await (async () => {
    switch (type_) {
      case "extension":
        return tenantOwns(extension, extension.organizationId, extension.id, id_, organizationId);
      case "ring_group":
        return tenantOwns(ringGroup, ringGroup.organizationId, ringGroup.id, id_, organizationId);
      case "ivr":
        return tenantOwns(ivrMenu, ivrMenu.organizationId, ivrMenu.id, id_, organizationId);
      case "time_condition":
        return tenantOwns(
          timeCondition, timeCondition.organizationId, timeCondition.id, id_, organizationId);
      case "queue":
        return tenantOwns(queue, queue.organizationId, queue.id, id_, organizationId);
      default:
        return false;
    }
  })();

  return owned
    ? null
    : `destination ${String(type_)}/${String(id_)} does not belong to this tenant`;
}

/* ---------------------------------------------------------------------------------------
 * Trunks
 * ------------------------------------------------------------------------------------ */

export const trunks = crudRoutes({
  table: trunk,
  orgColumn: trunk.organizationId,
  idColumn: trunk.id,
  entityType: "trunk",
  required: ["name", "host"],
  writable: [
    "name", "authMode", "host", "port", "transport", "username", "fromDomain",
    "codecPrefs", "priority", "carrierSigns", "enabled",
  ],
  // Carrier credentials never go back to a client, same rule as SIP passwords.
  present: ({ passwordEnc: _p, ...rest }) => rest,
  validate: async (body) => {
    if (body.authMode === "register" && !body.username) {
      return "username is required when authMode is register";
    }
    return null;
  },
  afterChange: async (organizationId, row, action) => {
    // An IP-authenticated trunk has to exist in Kamailio's address table before it can send
    // us calls - and 14-responsive-firewall.sh reads the same table, so this is also what
    // stops the firewall rate-limiting a carrier.
    if (action === "delete") {
      await removeTrunkAddress(row.id as string);
    } else if (row.authMode === "ip") {
      await syncTrunkAddress(row as never);
    }
    // permissions holds the address list in memory and will not notice the write otherwise.
    await reloadKamailio();
    await cacheRouteTable(organizationId);
  },
});

/**
 * Trunk credentials are set through a dedicated endpoint rather than the generic patch, so
 * the plaintext never appears in an audit diff and cannot be echoed back by a list call.
 */
const trunkSecrets = new Hono<AppEnv>();
trunkSecrets.use("*", requireTenant);
trunkSecrets.put("/:id/password", async (c) => {
  const { password } = await c.req.json<{ password?: string }>();
  if (!password) return c.json({ error: "password is required" }, 400);

  const [row] = await db
    .update(trunk)
    .set({ passwordEnc: encrypt(password) })
    .where(and(eq(trunk.id, c.req.param("id")), eq(trunk.organizationId, c.get("organizationId"))))
    .returning();
  if (!row) return c.json({ error: "Not found" }, 404);

  // Rotating a carrier credential is exactly what an audit trail is for - "who changed the
  // trunk password before it stopped authenticating" is unanswerable otherwise. The record
  // deliberately carries no before/after, so the secret is never written anywhere but the
  // encrypted column.
  await recordAudit(c, {
    action: "rotate-password",
    entityType: "trunk",
    entityId: row.id,
    after: { name: row.name, host: row.host, passwordRotated: true },
  });

  return c.json({ status: "updated" });
});
trunks.route("/", trunkSecrets);

/* ---------------------------------------------------------------------------------------
 * Routing
 * ------------------------------------------------------------------------------------ */

export const inboundRoutes = crudRoutes({
  table: inboundRoute,
  orgColumn: inboundRoute.organizationId,
  idColumn: inboundRoute.id,
  entityType: "inbound_route",
  required: ["didPattern", "destinationType"],
  writable: ["didPattern", "description", "destinationType", "destinationId", "priority", "enabled"],
  validate: async (body, organizationId, existing) =>
    badDestination(
      body.destinationType, body.destinationId, organizationId,
      existing?.destinationType, existing?.destinationId),
  afterChange: async (organizationId) => {
    await cacheInboundRoutes(organizationId);
  },
});

export const outboundRoutes = crudRoutes({
  table: outboundRoute,
  orgColumn: outboundRoute.organizationId,
  idColumn: outboundRoute.id,
  entityType: "outbound_route",
  required: ["name", "pattern"],
  writable: [
    "name", "pattern", "trunkId", "stripDigits", "prependDigits",
    "callerIdOverride", "priority", "isEmergency", "enabled",
  ],
  validate: async (body, organizationId, existing) => {
    // A trunk belonging to another tenant would route this tenant's calls out through
    // someone else's carrier, billed to them.
    if (body.trunkId !== undefined && body.trunkId !== null) {
      const owned = await tenantOwns(
        trunk, trunk.organizationId, trunk.id, body.trunkId, organizationId);
      if (!owned) return "trunkId does not belong to this tenant";
    }
    // An invalid pattern is not caught until a call matches it, at which point the Lua
    // handler silently skips the route and the call fails with no route. Reject it here.
    if (typeof body.pattern === "string") {
      try {
        new RegExp(body.pattern);
      } catch {
        return `pattern is not a valid regular expression: ${body.pattern}`;
      }
    }
    // Emergency routes bypass concurrent limits and time conditions by design, so flagging
    // one is a deliberate act that should not be possible by accident on a normal route.
    // Merged with the stored row for the same reason as the destination pairs: marking an
    // existing route as emergency sends only isEmergency, and reading the body alone would
    // reject it for having no trunk when it has had one all along.
    const effectiveTrunk = body.trunkId !== undefined ? body.trunkId : existing?.trunkId;
    const effectiveEmergency =
      body.isEmergency !== undefined ? body.isEmergency : existing?.isEmergency;
    if (effectiveEmergency === true && !effectiveTrunk) {
      return "an emergency route must have a trunk - it is the one route that must always work";
    }
    return null;
  },
  afterChange: async (organizationId) => {
    // The Lua handler matches patterns against this table locally, so it is the ruleset that
    // is cached, not per-number answers.
    await cacheRouteTable(organizationId);
  },
});

/* ---------------------------------------------------------------------------------------
 * Call flow
 * ------------------------------------------------------------------------------------ */

export const ringGroups = crudRoutes({
  table: ringGroup,
  orgColumn: ringGroup.organizationId,
  idColumn: ringGroup.id,
  entityType: "ring_group",
  required: ["number", "name"],
  writable: [
    "number", "name", "strategy", "ringTimeoutSec", "failoverType", "failoverId", "enabled",
  ],
  validate: async (body, organizationId, existing) =>
    badDestination(
      body.failoverType, body.failoverId, organizationId,
      existing?.failoverType, existing?.failoverId),
  afterChange: async (organizationId) => {
    await rebuildTenant(organizationId);
  },
});

/** Membership is its own resource - a ring group's members change far more often than the
 *  group itself, and a nested array would mean rewriting the whole group to add one person. */
const ringGroupMembers = new Hono<AppEnv>();
ringGroupMembers.use("*", requireTenant);

ringGroupMembers.get("/:id/members", async (c) => {
  const rows = await db
    .select({
      id: ringGroupMember.id,
      extensionId: ringGroupMember.extensionId,
      number: extension.number,
      displayName: extension.displayName,
      position: ringGroupMember.position,
      delaySec: ringGroupMember.delaySec,
    })
    .from(ringGroupMember)
    .innerJoin(extension, eq(ringGroupMember.extensionId, extension.id))
    .innerJoin(ringGroup, eq(ringGroupMember.ringGroupId, ringGroup.id))
    .where(
      and(
        eq(ringGroupMember.ringGroupId, c.req.param("id")),
        eq(ringGroup.organizationId, c.get("organizationId")),
      ),
    );
  return c.json(rows);
});

ringGroupMembers.post("/:id/members", async (c) => {
  const organizationId = c.get("organizationId");
  const groupId = c.req.param("id");
  const body = await c.req.json<{ extensionId?: string; position?: number; delaySec?: number }>();
  if (!body.extensionId) return c.json({ error: "extensionId is required" }, 400);

  // Both the group AND the extension must belong to this tenant - checking only one would let
  // a tenant add another tenant's extension to their own ring group.
  const [group] = await db.select().from(ringGroup)
    .where(and(eq(ringGroup.id, groupId), eq(ringGroup.organizationId, organizationId)));
  if (!group) return c.json({ error: "Ring group not found" }, 404);

  const [ext] = await db.select().from(extension)
    .where(and(eq(extension.id, body.extensionId), eq(extension.organizationId, organizationId)));
  if (!ext) return c.json({ error: "Extension not found" }, 404);

  const [row] = await db
    .insert(ringGroupMember)
    .values({
      id: crypto.randomUUID(),
      ringGroupId: groupId,
      extensionId: body.extensionId,
      position: body.position ?? 0,
      delaySec: body.delaySec ?? 0,
    })
    .onConflictDoNothing()
    .returning();

  await rebuildTenant(organizationId);
  return c.json(row ?? { status: "already a member" }, row ? 201 : 200);
});

ringGroupMembers.delete("/:id/members/:memberId", async (c) => {
  const [group] = await db.select().from(ringGroup)
    .where(and(eq(ringGroup.id, c.req.param("id")), eq(ringGroup.organizationId, c.get("organizationId"))));
  if (!group) return c.json({ error: "Ring group not found" }, 404);

  // Scoped to the verified group, not just the member id. Verifying only the group let a
  // tenant delete ANY member row by pairing their own group id with someone else's member id.
  const removed = await db
    .delete(ringGroupMember)
    .where(
      and(
        eq(ringGroupMember.id, c.req.param("memberId")),
        eq(ringGroupMember.ringGroupId, group.id),
      ),
    )
    .returning();
  if (removed.length === 0) return c.json({ error: "Member not found in this group" }, 404);

  await rebuildTenant(c.get("organizationId"));
  return c.body(null, 204);
});
ringGroups.route("/", ringGroupMembers);

export const ivrMenus = crudRoutes({
  table: ivrMenu,
  orgColumn: ivrMenu.organizationId,
  idColumn: ivrMenu.id,
  entityType: "ivr_menu",
  required: ["number", "name"],
  writable: [
    "number", "name", "greetingSound", "invalidSound", "timeoutSec",
    "maxRetries", "timeoutType", "timeoutId", "enabled",
  ],
  validate: async (body, organizationId, existing) =>
    badDestination(
      body.timeoutType, body.timeoutId, organizationId,
      existing?.timeoutType, existing?.timeoutId),
  afterChange: async (organizationId) => {
    await rebuildTenant(organizationId);
  },
});

/** IVR options hang off a menu rather than the organization, so they need their own scoping
 *  via the parent - crudRoutes cannot express that. */
const ivrOptions = new Hono<AppEnv>();
ivrOptions.use("*", requireTenant);

ivrOptions.get("/:id/options", async (c) => {
  const [menu] = await db.select().from(ivrMenu)
    .where(and(eq(ivrMenu.id, c.req.param("id")), eq(ivrMenu.organizationId, c.get("organizationId"))));
  if (!menu) return c.json({ error: "Not found" }, 404);
  const rows = await db.select().from(ivrOption).where(eq(ivrOption.ivrMenuId, menu.id));
  return c.json(rows);
});

ivrOptions.put("/:id/options/:digit", async (c) => {
  const [menu] = await db.select().from(ivrMenu)
    .where(and(eq(ivrMenu.id, c.req.param("id")), eq(ivrMenu.organizationId, c.get("organizationId"))));
  if (!menu) return c.json({ error: "Not found" }, 404);

  const body = await c.req.json<{ destinationType?: string; destinationId?: string; description?: string }>();
  if (!body.destinationType) return c.json({ error: "destinationType is required" }, 400);

  const problem = await badDestination(
    body.destinationType, body.destinationId, c.get("organizationId"));
  if (problem) return c.json({ error: problem }, 400);

  const [row] = await db
    .insert(ivrOption)
    .values({
      id: crypto.randomUUID(),
      ivrMenuId: menu.id,
      digit: c.req.param("digit"),
      destinationType: body.destinationType as never,
      destinationId: body.destinationId ?? null,
      description: body.description ?? null,
    })
    .onConflictDoUpdate({
      target: [ivrOption.ivrMenuId, ivrOption.digit],
      set: {
        destinationType: body.destinationType as never,
        destinationId: body.destinationId ?? null,
        description: body.description ?? null,
      },
    })
    .returning();

  await rebuildTenant(c.get("organizationId"));
  return c.json(row);
});

ivrOptions.delete("/:id/options/:digit", async (c) => {
  const [menu] = await db.select().from(ivrMenu)
    .where(and(eq(ivrMenu.id, c.req.param("id")), eq(ivrMenu.organizationId, c.get("organizationId"))));
  if (!menu) return c.json({ error: "Not found" }, 404);

  await db.delete(ivrOption)
    .where(and(eq(ivrOption.ivrMenuId, menu.id), eq(ivrOption.digit, c.req.param("digit"))));
  await rebuildTenant(c.get("organizationId"));
  return c.body(null, 204);
});
ivrMenus.route("/", ivrOptions);

export const timeConditions = crudRoutes({
  table: timeCondition,
  orgColumn: timeCondition.organizationId,
  idColumn: timeCondition.id,
  entityType: "time_condition",
  required: ["name", "rules"],
  writable: [
    "name", "timezone", "rules", "matchType", "matchId", "noMatchType", "noMatchId", "enabled",
  ],
  validate: async (body, organizationId, existing) => {
    const matchProblem = await badDestination(
      body.matchType, body.matchId, organizationId,
      existing?.matchType, existing?.matchId);
    if (matchProblem) return matchProblem;
    const noMatchProblem = await badDestination(
      body.noMatchType, body.noMatchId, organizationId,
      existing?.noMatchType, existing?.noMatchId);
    if (noMatchProblem) return noMatchProblem;

    // The rules are evaluated by Lua at call time, where a malformed shape means the condition
    // silently never matches and calls quietly take the wrong branch. Check it on the way in.
    if (body.rules !== undefined) {
      if (!Array.isArray(body.rules)) return "rules must be an array";
      for (const rule of body.rules as Record<string, unknown>[]) {
        if (rule.days !== undefined && !Array.isArray(rule.days)) {
          return "rule.days must be an array of weekday numbers";
        }
        for (const field of ["start", "end"]) {
          const v = rule[field];
          if (v !== undefined && !/^\d{2}:\d{2}$/.test(String(v))) {
            return `rule.${field} must be HH:MM`;
          }
        }
      }
    }
    return null;
  },
  afterChange: async (organizationId) => {
    await rebuildTenant(organizationId);
  },
});
