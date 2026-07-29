/**
 * Call detail records.
 *
 * FreeSWITCH is the source of truth, not Kamailio. Kamailio's `acc` table sees the SIP
 * transactions but not the B2BUA's view of the call - it has no billable-seconds figure, no
 * hangup cause from the media leg, and no channel variables, which is where tenant attribution
 * lives. `acc` remains useful as a cross-check and as the only record of calls rejected at the
 * edge before they ever reached FreeSWITCH; it is not what an invoice is built from.
 *
 * Records arrive from mod_xml_cdr, which posts on channel hangup. mod_xml_cdr RETRIES a failed
 * post, so ingestion has to be idempotent or a slow API turns into duplicate billing rows -
 * hence the unique index on call_uuid and the do-nothing conflict clause.
 */
import { XMLParser } from "fast-xml-parser";
import { randomUUID } from "node:crypto";
import { and, eq } from "drizzle-orm";
import { db } from "../db";
import { cdr, extension, tenantSettings, trunk } from "../db/schema";

/**
 * fast-xml-parser processes no DTDs and resolves no external entities, so a hostile CDR cannot
 * reach the filesystem or the network through the parser. `processEntities: false` also leaves
 * character entities alone, which matters because the values below are URL-decoded afterwards
 * and decoding twice would corrupt anything containing a literal percent sign.
 */
const parser = new XMLParser({
  ignoreAttributes: true,
  parseTagValue: false,
  processEntities: false,
  trimValues: true,
});

type Bag = Record<string, unknown>;

function str(v: unknown): string | null {
  if (v === undefined || v === null) return null;
  const s = String(v);
  return s === "" ? null : s;
}

/**
 * Values under <variables> are URL-encoded by FreeSWITCH; values under <caller_profile> are
 * not. Applying the wrong one either mangles the caller ID or leaves `%20` in it, and both look
 * like data-entry problems rather than a decode bug, so keep the two accessors separate.
 */
function decodeVar(v: unknown): string | null {
  const s = str(v);
  if (s === null) return null;
  try {
    return decodeURIComponent(s.replace(/\+/g, " "));
  } catch {
    // A stray % that is not a valid escape. Keep the raw value rather than dropping the record.
    return s;
  }
}

function epoch(v: unknown): Date | null {
  const s = str(v);
  if (s === null) return null;
  const n = Number(s);
  // FreeSWITCH writes 0 for "never happened" - an unanswered call has answer_epoch 0, and
  // turning that into 1970 would put it at the top of every "recent calls" list.
  if (!Number.isFinite(n) || n <= 0) return null;
  return new Date(n * 1000);
}

function int(v: unknown): number {
  const n = Number(str(v) ?? 0);
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : 0;
}

export type ParsedCdr = {
  callUuid: string;
  sipCallId: string | null;
  correlationId: string | null;
  organizationId: string | null;
  direction: "inbound" | "outbound" | "internal";
  callerNumber: string | null;
  callerName: string | null;
  destinationNumber: string;
  authUser: string | null;
  gatewayName: string | null;
  startedAt: Date;
  answeredAt: Date | null;
  endedAt: Date | null;
  durationSec: number;
  billsecSec: number;
  hangupCause: string | null;
  recordingPath: string | null;
  attestation: string | null;
  context: string | null;
};

/**
 * Turns one mod_xml_cdr document into the fields we store. Returns null when the document is
 * not a CDR or carries no channel uuid - without a uuid there is no idempotency key, and an
 * unkeyed insert is worse than a dropped record.
 */
export function parseCdrXml(xml: string): ParsedCdr | null {
  let doc: Bag;
  try {
    doc = parser.parse(xml) as Bag;
  } catch {
    return null;
  }

  const root = (doc.cdr ?? doc) as Bag;
  const vars = (root.variables ?? {}) as Bag;
  const callflow = root.callflow;
  // A call that was transferred or bridged has several <callflow> blocks. The FIRST is the
  // original leg - the number the caller actually dialled - and the last is wherever it ended
  // up. Billing and "who called us" both want the original.
  const flow = (Array.isArray(callflow) ? callflow[0] : callflow) as Bag | undefined;
  const profile = (flow?.caller_profile ?? {}) as Bag;

  const callUuid = decodeVar(vars.uuid) ?? decodeVar(vars.call_uuid);
  if (!callUuid) return null;

  const destination = str(profile.destination_number) ?? decodeVar(vars.destination_number);
  if (!destination) return null;

  const started =
    epoch(vars.start_epoch) ?? epoch(vars.profile_start_epoch) ?? new Date();

  /* The channel's own `direction` says which way the SIP leg went, which is not the same
     question as which way the CALL went - an internal extension-to-extension call is an inbound
     leg too. The context tells us more: our dialplan puts every tenant call in tenant_<orgId>,
     and a call that never touched a gateway never left the building. */
  const gatewayName = decodeVar(vars.sip_gateway_name) ?? decodeVar(vars.gateway_name);
  const legDirection = decodeVar(vars.direction);
  let direction: ParsedCdr["direction"];
  if (gatewayName) {
    direction = "outbound";
  } else if (legDirection === "outbound") {
    direction = "outbound";
  } else {
    direction = "inbound";
  }

  return {
    callUuid,
    sipCallId: decodeVar(vars.sip_call_id),
    // Set by the Kamailio ingress route and carried across the B2BUA. Without it one call is
    // four unlinked legs in a capture.
    correlationId: decodeVar(vars["sip_h_X-Correlation-ID"]) ?? decodeVar(vars.correlation_id),
    organizationId: decodeVar(vars["sip_h_X-Tenant-ID"]),
    direction,
    callerNumber: str(profile.caller_id_number) ?? decodeVar(vars.caller_id_number),
    callerName: str(profile.caller_id_name) ?? decodeVar(vars.caller_id_name),
    destinationNumber: destination,
    authUser: decodeVar(vars["sip_h_X-Auth-User"]) ?? str(profile.username),
    gatewayName,
    startedAt: started,
    answeredAt: epoch(vars.answer_epoch),
    endedAt: epoch(vars.end_epoch),
    durationSec: int(vars.duration),
    billsecSec: int(vars.billsec),
    hangupCause: decodeVar(vars.hangup_cause),
    recordingPath: decodeVar(vars.recording_file) ?? decodeVar(vars.last_recording),
    attestation: decodeVar(vars.sip_h_Attestation) ?? decodeVar(vars.stir_attestation),
    context: str(profile.context) ?? decodeVar(vars.context),
  };
}

/**
 * Resolves the tenant when the header is missing.
 *
 * X-Tenant-ID should always be there - it is set on the directory entry and the egress leg -
 * but a CDR with no tenant is unattributable and therefore unbillable, so fall back to the
 * dialplan context, which our handler always writes as `tenant_<organizationId>`.
 */
function tenantFromContext(context: string | null): string | null {
  if (!context || !context.startsWith("tenant_")) return null;
  return context.slice("tenant_".length) || null;
}

export async function ingestCdr(xml: string): Promise<{ stored: boolean; reason?: string }> {
  const parsed = parseCdrXml(xml);
  if (!parsed) return { stored: false, reason: "unparseable" };

  const organizationId = parsed.organizationId ?? tenantFromContext(parsed.context);
  if (!organizationId) {
    return { stored: false, reason: "no tenant attribution" };
  }

  // Confirm the tenant exists before inserting: organization_id is a foreign key, and a CDR
  // naming an unknown org would otherwise fail the insert and be retried by mod_xml_cdr for
  // ever.
  const tenant = await db.query.tenantSettings.findFirst({
    where: eq(tenantSettings.organizationId, organizationId),
  });
  if (!tenant) return { stored: false, reason: `unknown tenant ${organizationId}` };

  let extensionId: string | null = null;
  if (parsed.authUser) {
    const ext = await db.query.extension.findFirst({
      where: and(
        eq(extension.organizationId, organizationId),
        eq(extension.number, parsed.authUser),
      ),
    });
    extensionId = ext?.id ?? null;
  }

  let trunkId: string | null = null;
  if (parsed.gatewayName) {
    const t = await db.query.trunk.findFirst({
      where: and(eq(trunk.organizationId, organizationId), eq(trunk.name, parsed.gatewayName)),
    });
    trunkId = t?.id ?? null;
  }

  // An internal call is one with an extension on both ends. Determined here rather than in
  // parseCdrXml because it needs the database.
  let direction = parsed.direction;
  if (direction === "inbound" && extensionId) {
    const dialled = await db.query.extension.findFirst({
      where: and(
        eq(extension.organizationId, organizationId),
        eq(extension.number, parsed.destinationNumber),
      ),
    });
    if (dialled) direction = "internal";
  }

  await db
    .insert(cdr)
    .values({
      id: randomUUID(),
      organizationId,
      callUuid: parsed.callUuid,
      correlationId: parsed.correlationId,
      sipCallId: parsed.sipCallId,
      direction,
      callerNumber: parsed.callerNumber,
      callerName: parsed.callerName,
      destinationNumber: parsed.destinationNumber,
      extensionId,
      trunkId,
      startedAt: parsed.startedAt,
      answeredAt: parsed.answeredAt,
      endedAt: parsed.endedAt,
      durationSec: parsed.durationSec,
      billsecSec: parsed.billsecSec,
      hangupCause: parsed.hangupCause,
      recordingPath: parsed.recordingPath,
      attestation: parsed.attestation,
    })
    // The retry case. Doing nothing rather than updating is deliberate: the first record to
    // land is the one FreeSWITCH generated at hangup, and a retry carries identical content.
    .onConflictDoNothing({ target: cdr.callUuid });

  return { stored: true };
}
