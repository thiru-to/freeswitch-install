/**
 * Fax: the receive hook FreeSWITCH calls, and tenant-facing listing/download.
 */
import { Hono } from "hono";
import { and, desc, eq } from "drizzle-orm";
import { db } from "../db";
import { fax } from "../db/schema";
import { recordInboundFax, type FaxReport } from "../services/fax";
import { actionForMethod, requirePermission, requireTenant, type AppEnv } from "../middleware/tenant";

/* ---------------------------------------------------------------------------------------
 * Machine endpoint: fax_receive.lua reports here after rxfax completes.
 * Authenticated with the same gateway credential as the XML fallback - it is a machine, not
 * a user session.
 * ------------------------------------------------------------------------------------ */

export const faxHook = new Hono();

faxHook.use("*", async (c, next) => {
  const expected = process.env.FS_XML_GATEWAY_SECRET;
  if (!expected) return c.text("FS_XML_GATEWAY_SECRET is not configured", 500);
  const header = c.req.header("Authorization") ?? "";
  const [scheme, encoded] = header.split(" ");
  if (scheme !== "Basic" || !encoded) return c.text("Unauthorized", 401);
  const [, password] = Buffer.from(encoded, "base64").toString("utf8").split(":");
  if (password !== expected) return c.text("Unauthorized", 401);
  await next();
});

faxHook.post("/", async (c) => {
  try {
    const report = await c.req.json<FaxReport>();
    if (!report.callUuid || !report.domain || !report.did || !report.filePath) {
      return c.json({ error: "callUuid, domain, did and filePath are required" }, 400);
    }
    const id = await recordInboundFax(report);
    return c.json({ id, status: "recorded" }, id ? 201 : 202);
  } catch (err) {
    // Never fail loudly at FreeSWITCH: the TIFF is already on disk, and the Lua side is
    // fire-and-forget by design. Log so the discrepancy is visible.
    console.error("[fax] hook failed:", (err as Error).message);
    return c.json({ error: "recorded to disk only" }, 202);
  }
});

/* ---------------------------------------------------------------------------------------
 * Tenant-facing
 * ------------------------------------------------------------------------------------ */

export const faxes = new Hono<AppEnv>();
faxes.use("*", requireTenant);
/* A received fax is a recording of customer content, so it sits under the `recording` resource
   in the statement rather than getting a category of its own - viewer has no access, member can
   read, admin can delete. */
faxes.use("*", async (c, next) =>
  requirePermission("recording", actionForMethod(c.req.method))(c, next));

faxes.get("/", async (c) => {
  const rows = await db.query.fax.findMany({
    where: eq(fax.organizationId, c.get("organizationId")),
    orderBy: [desc(fax.receivedAt)],
    limit: 200,
  });
  // filePath is a server path - useful to us, meaningless and mildly leaky to a client.
  return c.json(rows.map(({ filePath: _p, ...rest }) => rest));
});

faxes.get("/:id/download", async (c) => {
  const row = await db.query.fax.findFirst({
    where: and(eq(fax.id, c.req.param("id")), eq(fax.organizationId, c.get("organizationId"))),
  });
  if (!row?.filePath) return c.json({ error: "Not found" }, 404);

  const file = Bun.file(row.filePath);
  if (!(await file.exists())) {
    // The row outliving the file is a real state - retention may have pruned it - and saying
    // so precisely beats a bare 404 that looks like a permissions problem.
    return c.json({ error: "The document is no longer on disk", receivedAt: row.receivedAt }, 410);
  }

  const isPdf = row.filePath.endsWith(".pdf");
  return new Response(file, {
    headers: {
      "Content-Type": isPdf ? "application/pdf" : "image/tiff",
      "Content-Disposition": `attachment; filename="fax-${row.didNumber}-${row.id.slice(0, 8)}${isPdf ? ".pdf" : ".tif"}"`,
    },
  });
});
