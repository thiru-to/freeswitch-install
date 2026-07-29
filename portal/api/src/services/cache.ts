/**
 * Redis write-through.
 *
 * This service is why Lua does not need to know our schema. The API is the only writer of the
 * cache that scripts/xml_handler.lua reads: it renders directory entries, route tables and DID
 * maps into Redis on every config change, and Lua just fetches them.
 *
 * Two things follow from that division:
 *
 * 1. **Cache shape is chosen per lookup, not uniformly.** Directory, internal calls and inbound
 *    DIDs have bounded key spaces, so the rendered answer is cached. Outbound destinations do
 *    not - every new number dialled would be a miss - so the tenant's *route table* is cached
 *    and Lua matches patterns locally. Caching outbound per-number would fill Redis with
 *    single-use keys and still hit the database on nearly every call.
 *
 * 2. **A cache write failing must not fail the config change.** The data is already in
 *    Postgres, and Lua falls back to Postgres then to mod_xml_curl. Cache staleness degrades
 *    latency, never correctness.
 */
import { and, eq } from "drizzle-orm";
import { db } from "../db";
import {
  extension,
  inboundRoute,
  ivrMenu,
  ivrOption,
  outboundRoute,
  ringGroup,
  ringGroupMember,
  tenantSettings,
  timeCondition,
  trunk,
} from "../db/schema";
import { decrypt } from "../lib/crypto";
import { esl } from "./esl";
import { keys, safeDel, safeDelPattern, safeSet } from "./redis";

/* ---------------------------------------------------------------------------------------
 * Directory
 * ------------------------------------------------------------------------------------ */

/**
 * The rendered `<user>` document for one extension.
 *
 * `cacheable` is emitted here because FreeSWITCH core honours it in
 * switch_xml_locate_user_merged - a second cache layer above Redis, inside FreeSWITCH itself.
 * A just-edited extension gets 0 so the next registration re-reads it.
 */
function renderDirectoryUser(
  ext: typeof extension.$inferSelect,
  tenant: typeof tenantSettings.$inferSelect,
  password: string,
  voicemailPin: string | null,
): string {
  const cacheMs = ext.directoryCacheMs ?? tenant.directoryCacheMs;
  const codecs = ext.codecPrefs ?? "OPUS,G722,PCMU,PCMA";
  const callerName = ext.callerIdName ?? tenant.defaultCallerIdName ?? ext.displayName;
  const callerNumber = ext.callerIdNumber ?? tenant.defaultCallerIdNumber ?? ext.number;

  /* mod_voicemail falls back to the `password` param when `vm-password` is absent, which means
     an unset PIN silently makes the mailbox require the 24-character random SIP password on a
     numeric keypad - unreachable rather than insecure, and confusing to diagnose. */
  const vmPin = voicemailPin
    ? `<param name="vm-password" value="${escapeXml(voicemailPin)}"/>`
    : "";
  /* vm-attach-file is what makes the notification useful; without it the email says a message
     arrived and the user still has to call in to hear it. */
  const vmEmail = ext.voicemailEmail
    ? `<param name="vm-email-all-messages" value="true"/>
    <param name="vm-attach-file" value="true"/>
    <param name="vm-keep-local-after-email" value="true"/>
    <param name="vm-mailto" value="${escapeXml(ext.voicemailEmail)}"/>`
    : "";

  return `<user id="${ext.number}" cacheable="${cacheMs}">
  <params>
    <param name="password" value="${escapeXml(password)}"/>
    <param name="vm-enabled" value="${ext.voicemailEnabled ? "true" : "false"}"/>
    ${vmPin}
    ${vmEmail}
  </params>
  <variables>
    <variable name="organization_id" value="${ext.organizationId}"/>
    <variable name="user_context" value="tenant_${tenant.organizationId}"/>
    <variable name="effective_caller_id_name" value="${escapeXml(callerName)}"/>
    <variable name="effective_caller_id_number" value="${escapeXml(callerNumber)}"/>
    <variable name="outbound_caller_id_name" value="${escapeXml(callerName)}"/>
    <variable name="outbound_caller_id_number" value="${escapeXml(callerNumber)}"/>
    <variable name="absolute_codec_string" value="${escapeXml(codecs)}"/>
    <variable name="max_concurrent" value="${ext.maxConcurrentCalls ?? tenant.maxConcurrentCalls}"/>
    <variable name="sip_h_X-Tenant-ID" value="${ext.organizationId}"/>
    <variable name="sip_h_X-Auth-User" value="${ext.number}"/>
  </variables>
</user>`;
}

/** XML attribute values are attacker-influenced (display names, emails) - escape them. */
function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

export async function cacheExtension(extensionId: string): Promise<void> {
  const ext = await db.query.extension.findFirst({ where: eq(extension.id, extensionId) });
  if (!ext) return;

  const tenant = await db.query.tenantSettings.findFirst({
    where: eq(tenantSettings.organizationId, ext.organizationId),
  });
  if (!tenant) return;

  if (!ext.enabled) {
    await invalidateExtension(ext.organizationId, ext.number, tenant.sipDomain);
    return;
  }

  const password = decrypt(ext.sipPasswordEnc);
  const pin = ext.voicemailPinEnc ? decrypt(ext.voicemailPinEnc) : null;
  const xml = renderDirectoryUser(ext, tenant, password, pin);

  await safeSet(keys.directory(tenant.sipDomain, ext.number), xml);
  // Drop FreeSWITCH's own copy so the edit is visible on the next lookup rather than after
  // the cacheable TTL expires.
  await esl.flushXmlCache(ext.number, tenant.sipDomain);
}

export async function invalidateExtension(
  _organizationId: string,
  number: string,
  sipDomain: string,
): Promise<void> {
  await safeDel(keys.directory(sipDomain, number));
  await esl.flushXmlCache(number, sipDomain);
}

/* ---------------------------------------------------------------------------------------
 * Route table
 * ------------------------------------------------------------------------------------ */

export type CachedRoute = {
  id: string;
  pattern: string;
  priority: number;
  isEmergency: boolean;
  stripDigits: number;
  prependDigits: string | null;
  callerIdOverride: string | null;
  trunk: { id: string; name: string; host: string; port: number; transport: string } | null;
};

/**
 * The tenant's outbound routes, ordered so Lua can evaluate top-down and stop at the first
 * match.
 *
 * Emergency routes sort first unconditionally. That ordering is the mechanism by which an
 * emergency call bypasses concurrent-call limits and time conditions - if it sorted by
 * priority alongside everything else, a misconfigured priority could put a fraud check ahead
 * of a 911 call.
 */
export async function cacheRouteTable(organizationId: string): Promise<void> {
  const tenant = await db.query.tenantSettings.findFirst({
    where: eq(tenantSettings.organizationId, organizationId),
  });
  if (!tenant) return;

  const rows = await db
    .select({
      route: outboundRoute,
      trunkRow: trunk,
    })
    .from(outboundRoute)
    .leftJoin(trunk, eq(outboundRoute.trunkId, trunk.id))
    .where(
      and(eq(outboundRoute.organizationId, organizationId), eq(outboundRoute.enabled, true)),
    );

  const routes: CachedRoute[] = rows
    .map(({ route, trunkRow }) => ({
      id: route.id,
      pattern: route.pattern,
      priority: route.priority,
      isEmergency: route.isEmergency,
      stripDigits: route.stripDigits,
      prependDigits: route.prependDigits,
      callerIdOverride: route.callerIdOverride,
      trunk: trunkRow
        ? {
            id: trunkRow.id,
            name: trunkRow.name,
            host: trunkRow.host,
            port: trunkRow.port,
            transport: trunkRow.transport,
          }
        : null,
    }))
    .sort((a, b) => {
      if (a.isEmergency !== b.isEmergency) return a.isEmergency ? -1 : 1;
      return a.priority - b.priority;
    });

  await safeSet(keys.routes(tenant.sipDomain), JSON.stringify(routes));
}

/* ---------------------------------------------------------------------------------------
 * Inbound DIDs and tenant settings
 * ------------------------------------------------------------------------------------ */

export async function cacheInboundRoutes(organizationId: string): Promise<void> {
  const tenant = await db.query.tenantSettings.findFirst({
    where: eq(tenantSettings.organizationId, organizationId),
  });
  if (!tenant) return;

  const rows = await db.query.inboundRoute.findMany({
    where: and(
      eq(inboundRoute.organizationId, organizationId),
      eq(inboundRoute.enabled, true),
    ),
  });

  // Bounded key space, so one key per DID is fine and gives Lua an O(1) lookup.
  await Promise.all(
    rows.map((r) =>
      safeSet(
        keys.did(tenant.sipDomain, r.didPattern),
        JSON.stringify({
          destinationType: r.destinationType,
          destinationId: r.destinationId,
        }),
      ),
    ),
  );
}

/** Settings Lua needs at call time. Kept small - this is read on the hot path. */
export async function cacheTenantSettings(organizationId: string): Promise<void> {
  const tenant = await db.query.tenantSettings.findFirst({
    where: eq(tenantSettings.organizationId, organizationId),
  });
  if (!tenant) return;

  await safeSet(
    keys.tenant(tenant.sipDomain),
    JSON.stringify({
      organizationId: tenant.organizationId,
      sipDomain: tenant.sipDomain,
      tier: tenant.tier,
      dispatcherSetId: tenant.dispatcherSetId,
      egressMode: tenant.egressMode,
      maxConcurrentCalls: tenant.maxConcurrentCalls,
      recordingPolicy: tenant.recordingPolicy,
      timezone: tenant.timezone,
      enabled: tenant.enabled,
    }),
  );
}

/* ---------------------------------------------------------------------------------------
 * Call-flow objects
 *
 * These are read by the Lua scripts at call time (ring_group.lua, ivr.lua,
 * time_condition.lua). Cached whole - a ring group with its members, a menu with its options -
 * because the alternative is the script making several round trips mid-call, and each one is
 * dead air the caller can hear.
 * ------------------------------------------------------------------------------------ */

export async function cacheRingGroups(organizationId: string): Promise<void> {
  const tenant = await db.query.tenantSettings.findFirst({
    where: eq(tenantSettings.organizationId, organizationId),
  });
  if (!tenant) return;

  const groups = await db.query.ringGroup.findMany({
    where: and(eq(ringGroup.organizationId, organizationId), eq(ringGroup.enabled, true)),
  });

  for (const group of groups) {
    const members = await db
      .select({
        number: extension.number,
        position: ringGroupMember.position,
        delaySec: ringGroupMember.delaySec,
        enabled: extension.enabled,
      })
      .from(ringGroupMember)
      .innerJoin(extension, eq(ringGroupMember.extensionId, extension.id))
      .where(eq(ringGroupMember.ringGroupId, group.id));

    await safeSet(
      keys.ringGroup(tenant.sipDomain, group.id),
      JSON.stringify({
        id: group.id,
        number: group.number,
        name: group.name,
        strategy: group.strategy,
        ringTimeoutSec: group.ringTimeoutSec,
        failoverType: group.failoverType,
        failoverId: group.failoverId,
        // Disabled extensions are filtered here rather than in Lua: a disabled member should
        // not even be attempted, and doing it at cache time keeps the call path simple.
        members: members
          .filter((m) => m.enabled)
          .sort((a, b) => a.position - b.position)
          .map((m) => ({ number: m.number, delaySec: m.delaySec })),
      }),
    );

    await cacheFeatureNumber(tenant.sipDomain, group.number, "ring_group", group.id);
  }
}

/**
 * Makes a call-flow object reachable by dialling its number from inside the tenant.
 *
 * Deliberately a separate small key rather than folding the number into the object: the
 * dialplan lookup starts from a dialled string and has no id to work with, so it needs an
 * index in that direction.
 */
async function cacheFeatureNumber(
  domain: string,
  number: string | null,
  type: string,
  id: string,
): Promise<void> {
  if (!number) return;
  await safeSet(keys.featureNumber(domain, number), JSON.stringify({ type, id }));
}

export async function cacheIvrMenus(organizationId: string): Promise<void> {
  const tenant = await db.query.tenantSettings.findFirst({
    where: eq(tenantSettings.organizationId, organizationId),
  });
  if (!tenant) return;

  const menus = await db.query.ivrMenu.findMany({
    where: and(eq(ivrMenu.organizationId, organizationId), eq(ivrMenu.enabled, true)),
  });

  for (const menu of menus) {
    const options = await db.query.ivrOption.findMany({
      where: eq(ivrOption.ivrMenuId, menu.id),
    });
    await safeSet(
      keys.ivr(tenant.sipDomain, menu.id),
      JSON.stringify({
        id: menu.id,
        number: menu.number,
        name: menu.name,
        greetingSound: menu.greetingSound,
        invalidSound: menu.invalidSound,
        timeoutSec: menu.timeoutSec,
        maxRetries: menu.maxRetries,
        timeoutType: menu.timeoutType,
        timeoutId: menu.timeoutId,
        // Keyed by digit so Lua can look up in one step rather than scanning.
        options: Object.fromEntries(
          options.map((o) => [o.digit, { type: o.destinationType, id: o.destinationId }]),
        ),
      }),
    );

    await cacheFeatureNumber(tenant.sipDomain, menu.number, "ivr", menu.id);
  }
}

export async function cacheTimeConditions(organizationId: string): Promise<void> {
  const tenant = await db.query.tenantSettings.findFirst({
    where: eq(tenantSettings.organizationId, organizationId),
  });
  if (!tenant) return;

  const conditions = await db.query.timeCondition.findMany({
    where: and(
      eq(timeCondition.organizationId, organizationId),
      eq(timeCondition.enabled, true),
    ),
  });

  for (const cond of conditions) {
    await safeSet(
      keys.timeCondition(tenant.sipDomain, cond.id),
      JSON.stringify({
        id: cond.id,
        name: cond.name,
        timezone: cond.timezone,
        rules: cond.rules,
        matchType: cond.matchType,
        matchId: cond.matchId,
        noMatchType: cond.noMatchType,
        noMatchId: cond.noMatchId,
      }),
    );
  }
}

/**
 * Rebuilds everything for one tenant. Used on provisioning, after a bulk import, and as the
 * repair action when the cache is suspected stale.
 *
 * Purges first, because the individual cache builders only ever SET. Without the purge a
 * deleted ring group keeps answering, and a ring group renumbered from 600 to 610 answers on
 * both - the sort of ghost that survives every subsequent rebuild and is diagnosed by nobody.
 *
 * The gap between purge and repopulate is deliberate and safe: a lookup landing in it misses
 * Redis and falls through to mod_xml_curl, which serves the same answer from Postgres. Slower
 * for a few milliseconds, never wrong.
 */
export async function rebuildTenant(organizationId: string): Promise<void> {
  const existing = await db.query.tenantSettings.findFirst({
    where: eq(tenantSettings.organizationId, organizationId),
  });
  if (existing) {
    for (const pattern of keys.tenantPatterns(existing.sipDomain)) {
      await safeDelPattern(pattern);
    }
  }

  await cacheTenantSettings(organizationId);
  await cacheRouteTable(organizationId);
  await cacheInboundRoutes(organizationId);
  await cacheRingGroups(organizationId);
  await cacheIvrMenus(organizationId);
  await cacheTimeConditions(organizationId);

  const extensions = await db.query.extension.findMany({
    where: eq(extension.organizationId, organizationId),
  });
  for (const ext of extensions) {
    await cacheExtension(ext.id);
  }
}
