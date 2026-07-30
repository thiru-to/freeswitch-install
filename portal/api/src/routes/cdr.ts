/**
 * Call history, read-only.
 *
 * No write routes at all. CDRs are a record of what happened, and a phone system whose billing
 * history can be edited through its own API is not one anyone should buy - correcting a record
 * is a support action against the database, deliberately outside the normal path.
 */
import { Hono } from "hono";
import { and, count, desc, eq, gte, ilike, lte, or, sql } from "drizzle-orm";
import { db } from "../db";
import { cdr, extension, trunk } from "../db/schema";
import { requirePermission, requireTenant, type AppEnv } from "../middleware/tenant";

export const cdrs = new Hono<AppEnv>();
cdrs.use("*", requireTenant);
/* Read-only routes, so `read` is the only action needed. The statement also defines cdr:export,
   which is reserved for a bulk download endpoint that does not exist yet - viewer and member
   have read but not export, and that distinction only becomes load-bearing when it does. */
cdrs.use("*", requirePermission("cdr", "read"));

const MAX_LIMIT = 200;

/** Rejects a date that would silently become "now" or an Invalid Date in a range filter. */
function parseDate(value: string | undefined): Date | null | "invalid" {
  if (!value) return null;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? "invalid" : d;
}

cdrs.get("/", async (c) => {
  const organizationId = c.get("organizationId");
  const q = c.req.query();

  const limit = Math.min(Math.max(Number(q.limit ?? 50) || 50, 1), MAX_LIMIT);
  const offset = Math.max(Number(q.offset ?? 0) || 0, 0);

  const from = parseDate(q.from);
  const to = parseDate(q.to);
  if (from === "invalid" || to === "invalid") {
    return c.json({ error: "from and to must be parseable dates" }, 400);
  }

  // organizationId first and unconditionally. Every other clause is optional; this one is the
  // isolation boundary and must not be reachable through any code path that omits it.
  const filters = [eq(cdr.organizationId, organizationId)];

  if (q.direction) {
    if (!["inbound", "outbound", "internal"].includes(q.direction)) {
      return c.json({ error: "direction must be inbound, outbound or internal" }, 400);
    }
    filters.push(eq(cdr.direction, q.direction as "inbound" | "outbound" | "internal"));
  }
  if (q.extensionId) filters.push(eq(cdr.extensionId, q.extensionId));
  if (from) filters.push(gte(cdr.startedAt, from));
  if (to) filters.push(lte(cdr.startedAt, to));
  if (q.answered === "true") filters.push(sql`${cdr.answeredAt} is not null`);
  if (q.answered === "false") filters.push(sql`${cdr.answeredAt} is null`);

  if (q.number) {
    /* Drizzle parameterises this, so the wildcards are data rather than pattern syntax - but
       an operator searching for a number containing % or _ would still get surprising matches,
       so escape them into literals. */
    const term = `%${q.number.replace(/[\\%_]/g, "\\$&")}%`;
    const numberMatch = or(
      ilike(cdr.callerNumber, term),
      ilike(cdr.destinationNumber, term),
    );
    if (numberMatch) filters.push(numberMatch);
  }

  const where = and(...filters);

  const rows = await db
    .select({
      id: cdr.id,
      callUuid: cdr.callUuid,
      direction: cdr.direction,
      callerNumber: cdr.callerNumber,
      callerName: cdr.callerName,
      destinationNumber: cdr.destinationNumber,
      startedAt: cdr.startedAt,
      answeredAt: cdr.answeredAt,
      endedAt: cdr.endedAt,
      durationSec: cdr.durationSec,
      billsecSec: cdr.billsecSec,
      hangupCause: cdr.hangupCause,
      attestation: cdr.attestation,
      extensionNumber: extension.number,
      extensionName: extension.displayName,
      trunkName: trunk.name,
    })
    .from(cdr)
    .leftJoin(extension, eq(cdr.extensionId, extension.id))
    .leftJoin(trunk, eq(cdr.trunkId, trunk.id))
    .where(where)
    .orderBy(desc(cdr.startedAt))
    .limit(limit)
    .offset(offset);

  // Total for the same filter set, so the portal can page without guessing.
  const [totals] = await db.select({ total: count() }).from(cdr).where(where);

  return c.json({ rows, total: totals?.total ?? 0, limit, offset });
});

/**
 * Aggregates for the dashboard. A separate endpoint rather than a flag on the list, because the
 * portal wants both at once and computing them from a page of rows would be wrong.
 */
cdrs.get("/summary", async (c) => {
  const organizationId = c.get("organizationId");
  const from = parseDate(c.req.query("from"));
  const to = parseDate(c.req.query("to"));
  if (from === "invalid" || to === "invalid") {
    return c.json({ error: "from and to must be parseable dates" }, 400);
  }

  const filters = [eq(cdr.organizationId, organizationId)];
  if (from) filters.push(gte(cdr.startedAt, from));
  if (to) filters.push(lte(cdr.startedAt, to));

  const [row] = await db
    .select({
      calls: count(),
      answered: sql<number>`count(*) filter (where ${cdr.answeredAt} is not null)`.mapWith(Number),
      inbound: sql<number>`count(*) filter (where ${cdr.direction} = 'inbound')`.mapWith(Number),
      outbound: sql<number>`count(*) filter (where ${cdr.direction} = 'outbound')`.mapWith(Number),
      internal: sql<number>`count(*) filter (where ${cdr.direction} = 'internal')`.mapWith(Number),
      billableSec: sql<number>`coalesce(sum(${cdr.billsecSec}), 0)`.mapWith(Number),
    })
    .from(cdr)
    .where(and(...filters));

  const calls = row?.calls ?? 0;
  const answered = row?.answered ?? 0;
  return c.json({
    calls,
    answered,
    // Expressed as a fraction rather than a percentage so the client decides the rounding.
    answerRate: calls > 0 ? answered / calls : null,
    inbound: row?.inbound ?? 0,
    outbound: row?.outbound ?? 0,
    internal: row?.internal ?? 0,
    billableSec: row?.billableSec ?? 0,
  });
});

cdrs.get("/:id", async (c) => {
  const row = await db.query.cdr.findFirst({
    where: and(eq(cdr.id, c.req.param("id")), eq(cdr.organizationId, c.get("organizationId"))),
  });
  if (!row) return c.json({ error: "Not found" }, 404);
  return c.json(row);
});
