/**
 * FreeSWITCH XML gateway — the FALLBACK path.
 *
 * scripts/xml_handler.lua serves these lookups from Redis in-process. FreeSWITCH tries
 * bindings in order (switch_xml.c loops over them, continuing past any that returns NULL or
 * `status="not found"`), so mod_xml_curl is bound second and only reaches here when Lua missed
 * or errored.
 *
 * That means this endpoint is for correctness, not throughput — but it must still answer
 * correctly, because when it is being used something has already gone wrong and this is what
 * keeps calls flowing.
 *
 * Authentication is HTTP Basic via mod_xml_curl's `gateway-credentials`. It runs on loopback
 * (or node-local on a split deployment), never exposed.
 */
import { Hono } from "hono";
import { and, eq } from "drizzle-orm";
import { db } from "../db";
import { extension, inboundRoute, tenantSettings } from "../db/schema";
import { decrypt } from "../lib/crypto";
import { env } from "../env";

export const fsXml = new Hono();

/** FreeSWITCH treats any non-XML or unparseable response as a hard failure, so always answer. */
const NOT_FOUND = `<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<document type="freeswitch/xml">
  <section name="result">
    <result status="not found"/>
  </section>
</document>`;

function wrap(sectionName: string, inner: string): string {
  return `<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<document type="freeswitch/xml">
  <section name="${sectionName}">
${inner}
  </section>
</document>`;
}

function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

/**
 * Constant-time comparison. A timing side-channel on a loopback credential is a stretch, but
 * this is the one place a machine credential is checked and the cost is nothing.
 */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

fsXml.use("*", async (c, next) => {
  const expected = process.env.FS_XML_GATEWAY_SECRET;
  if (!expected) {
    // Fail closed. An unauthenticated XML gateway hands out SIP passwords.
    return c.text("FS_XML_GATEWAY_SECRET is not configured", 500);
  }
  const header = c.req.header("Authorization") ?? "";
  const [scheme, encoded] = header.split(" ");
  if (scheme !== "Basic" || !encoded) return c.text("Unauthorized", 401);

  const [, password] = Buffer.from(encoded, "base64").toString("utf8").split(":");
  if (!password || !safeEqual(password, expected)) return c.text("Unauthorized", 401);

  await next();
});

fsXml.post("/", async (c) => {
  const form = await c.req.parseBody();
  const section = String(form["section"] ?? "");

  try {
    switch (section) {
      case "directory":
        return c.text(await handleDirectory(form), 200, { "Content-Type": "text/xml" });
      case "dialplan":
        return c.text(await handleDialplan(form), 200, { "Content-Type": "text/xml" });
      case "configuration":
        return c.text(NOT_FOUND, 200, { "Content-Type": "text/xml" });
      default:
        return c.text(NOT_FOUND, 200, { "Content-Type": "text/xml" });
    }
  } catch (err) {
    // Never 500 at FreeSWITCH: a non-XML body is a hard failure that drops the call. Returning
    // "not found" lets the next binding, or the static fallback directory, answer.
    console.error(`[fs-xml] ${section} lookup failed:`, (err as Error).message);
    return c.text(NOT_FOUND, 200, { "Content-Type": "text/xml" });
  }
});

async function handleDirectory(form: Record<string, unknown>): Promise<string> {
  const domain = String(form["domain"] ?? form["sip_auth_realm"] ?? "");
  const user = String(form["user"] ?? form["sip_auth_username"] ?? "");
  if (!domain || !user) return NOT_FOUND;

  const tenant = await db.query.tenantSettings.findFirst({
    where: and(eq(tenantSettings.sipDomain, domain), eq(tenantSettings.enabled, true)),
  });
  if (!tenant) return NOT_FOUND;

  const ext = await db.query.extension.findFirst({
    where: and(
      eq(extension.organizationId, tenant.organizationId),
      eq(extension.number, user),
      eq(extension.enabled, true),
    ),
  });
  if (!ext) return NOT_FOUND;

  const password = decrypt(ext.sipPasswordEnc);
  const cacheMs = ext.directoryCacheMs ?? tenant.directoryCacheMs;
  const codecs = ext.codecPrefs ?? "OPUS,G722,PCMU,PCMA";
  const cidName = ext.callerIdName ?? tenant.defaultCallerIdName ?? ext.displayName;
  const cidNumber = ext.callerIdNumber ?? tenant.defaultCallerIdNumber ?? ext.number;

  return wrap(
    "directory",
    `    <domain name="${escapeXml(domain)}">
      <params>
        <param name="dial-string" value="{^^:sip_invite_domain=\${dialed_domain}:presence_id=\${dialed_user}@\${dialed_domain}}\${sofia_contact(\${dialed_user}@\${dialed_domain})}"/>
      </params>
      <user id="${escapeXml(ext.number)}" cacheable="${cacheMs}">
        <params>
          <param name="password" value="${escapeXml(password)}"/>
          <param name="vm-enabled" value="${ext.voicemailEnabled ? "true" : "false"}"/>
        </params>
        <variables>
          <variable name="organization_id" value="${escapeXml(ext.organizationId)}"/>
          <variable name="user_context" value="tenant_${escapeXml(tenant.organizationId)}"/>
          <variable name="effective_caller_id_name" value="${escapeXml(cidName)}"/>
          <variable name="effective_caller_id_number" value="${escapeXml(cidNumber)}"/>
          <variable name="absolute_codec_string" value="${escapeXml(codecs)}"/>
          <variable name="sip_h_X-Tenant-ID" value="${escapeXml(ext.organizationId)}"/>
          <variable name="sip_h_X-Auth-User" value="${escapeXml(ext.number)}"/>
        </variables>
      </user>
    </domain>`,
  );
}

async function handleDialplan(form: Record<string, unknown>): Promise<string> {
  const domain = String(form["variable_sip_auth_realm"] ?? form["variable_domain_name"] ?? "");
  const destination = String(form["Caller-Destination-Number"] ?? form["destination_number"] ?? "");
  if (!domain || !destination) return NOT_FOUND;

  const tenant = await db.query.tenantSettings.findFirst({
    where: and(eq(tenantSettings.sipDomain, domain), eq(tenantSettings.enabled, true)),
  });
  if (!tenant) return NOT_FOUND;

  // Internal extension first - the common case and the cheapest lookup.
  const ext = await db.query.extension.findFirst({
    where: and(
      eq(extension.organizationId, tenant.organizationId),
      eq(extension.number, destination),
      eq(extension.enabled, true),
    ),
  });
  if (ext) {
    return wrap(
      "dialplan",
      `    <context name="tenant_${escapeXml(tenant.organizationId)}">
      <extension name="internal_${escapeXml(destination)}">
        <condition field="destination_number" expression="^${escapeXml(destination)}$">
          <action application="set" data="hangup_after_bridge=true"/>
          <action application="bridge" data="user/${escapeXml(destination)}@${escapeXml(domain)}"/>
        </condition>
      </extension>
    </context>`,
    );
  }

  // Then an inbound DID.
  const did = await db.query.inboundRoute.findFirst({
    where: and(
      eq(inboundRoute.organizationId, tenant.organizationId),
      eq(inboundRoute.didPattern, destination),
      eq(inboundRoute.enabled, true),
    ),
  });
  if (did?.destinationType === "extension" && did.destinationId) {
    const target = await db.query.extension.findFirst({
      where: eq(extension.id, did.destinationId),
    });
    if (target) {
      return wrap(
        "dialplan",
        `    <context name="tenant_${escapeXml(tenant.organizationId)}">
      <extension name="did_${escapeXml(destination)}">
        <condition field="destination_number" expression="^${escapeXml(destination)}$">
          <action application="bridge" data="user/${escapeXml(target.number)}@${escapeXml(domain)}"/>
        </condition>
      </extension>
    </context>`,
      );
    }
  }

  // Outbound and the richer destination types (IVR, ring group, time condition) are served by
  // the Lua handler, which holds the route table and can evaluate patterns. Reaching this
  // point means Lua was unavailable, so decline rather than guess at routing that could send
  // a call to the wrong carrier.
  console.warn(
    `[fs-xml] dialplan fallback could not resolve ${destination}@${domain} — ` +
      `Lua handler unavailable and this path does not do pattern routing`,
  );
  return NOT_FOUND;
}

export { env };
