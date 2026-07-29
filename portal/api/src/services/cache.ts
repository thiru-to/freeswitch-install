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
  outboundRoute,
  tenantSettings,
  trunk,
} from "../db/schema";
import { decrypt } from "../lib/crypto";
import { esl } from "./esl";
import { keys, safeDel, safeSet } from "./redis";

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
): string {
  const cacheMs = ext.directoryCacheMs ?? tenant.directoryCacheMs;
  const codecs = ext.codecPrefs ?? "OPUS,G722,PCMU,PCMA";
  const callerName = ext.callerIdName ?? tenant.defaultCallerIdName ?? ext.displayName;
  const callerNumber = ext.callerIdNumber ?? tenant.defaultCallerIdNumber ?? ext.number;

  return `<user id="${ext.number}" cacheable="${cacheMs}">
  <params>
    <param name="password" value="${escapeXml(password)}"/>
    <param name="vm-enabled" value="${ext.voicemailEnabled ? "true" : "false"}"/>
    ${ext.voicemailEmail ? `<param name="vm-email-all-messages" value="true"/>
    <param name="vm-mailto" value="${escapeXml(ext.voicemailEmail)}"/>` : ""}
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
  const xml = renderDirectoryUser(ext, tenant, password);

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

/**
 * Rebuilds everything for one tenant. Used on provisioning, after a bulk import, and as the
 * repair action when the cache is suspected stale.
 */
export async function rebuildTenant(organizationId: string): Promise<void> {
  await cacheTenantSettings(organizationId);
  await cacheRouteTable(organizationId);
  await cacheInboundRoutes(organizationId);

  const extensions = await db.query.extension.findMany({
    where: eq(extension.organizationId, organizationId),
  });
  for (const ext of extensions) {
    await cacheExtension(ext.id);
  }
}
