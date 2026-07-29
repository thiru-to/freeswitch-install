/**
 * Shared CRUD scaffolding for tenant-scoped resources.
 *
 * Five near-identical route files is exactly where a missing `organizationId` filter slips in,
 * and in a multi-tenant system that is a data breach rather than a bug. Centralising the
 * scoping means a resource cannot be added without it: the org filter is applied here, not by
 * each route remembering to.
 *
 * Every mutation also audits and fires an after-hook, because a change that lands in Postgres
 * but never reaches Redis or Kamailio leaves the system internally inconsistent in a way that
 * only shows up as a call failing hours later.
 */
import { randomUUID } from "node:crypto";
import { Hono } from "hono";
import { and, eq, type SQL } from "drizzle-orm";
import type { PgTable, PgColumn } from "drizzle-orm/pg-core";
import { db } from "../db";
import { recordAudit } from "./audit";
import { requireTenant, type AppEnv } from "../middleware/tenant";

type Row = Record<string, unknown>;

export type CrudOptions<T extends PgTable> = {
  table: T;
  /** The tenant column. Named explicitly so a table without one cannot be wired up by mistake. */
  orgColumn: PgColumn;
  idColumn: PgColumn;
  entityType: string;

  /** Whitelist of writable columns. Anything else in the body is ignored, so a client cannot
   *  set organizationId, id, or timestamps by including them. */
  writable: readonly string[];
  required?: readonly string[];

  /** Strips or transforms a row before it goes to the client - secrets, server paths. */
  present?: (row: Row) => Row;

  /** Runs after a successful create/update/delete. This is where cache write-through and the
   *  Kamailio projection happen; failures are logged, never fatal to the request that already
   *  committed. */
  afterChange?: (organizationId: string, row: Row, action: string) => Promise<void>;

  /**
   * Extra validation. Return a string to reject with 400.
   *
   * `existing` is the pre-update row on a PATCH, and undefined on a create. Validators that
   * check a pair of fields together MUST use it: a PATCH carries only the fields being changed,
   * so validating the body alone means half a pair looks absent and the check is skipped
   * entirely. That is how a cross-tenant id gets written by sending it without its type.
   */
  validate?: (
    body: Row,
    organizationId: string,
    existing?: Row,
  ) => Promise<string | null>;
};

/**
 * Confirms a referenced row belongs to this tenant.
 *
 * Scoping the resource being written is not enough. A foreign key points at ANOTHER row, and
 * nothing stops a client sending an id belonging to a different tenant - the insert succeeds
 * because the column only has a foreign-key constraint, not a tenancy one.
 *
 * The worst case is not a leak but a cost: an outbound route referencing another tenant's
 * trunk sends your calls out through their carrier, billed to them.
 */
export async function tenantOwns(
  table: PgTable,
  orgColumn: PgColumn,
  idColumn: PgColumn,
  id: unknown,
  organizationId: string,
): Promise<boolean> {
  if (typeof id !== "string" || id === "") return false;
  const rows = await db
    .select({ id: idColumn })
    .from(table)
    .where(and(eq(idColumn, id), eq(orgColumn, organizationId)))
    .limit(1);
  return rows.length > 0;
}

function pick(body: Row, writable: readonly string[]): Row {
  const out: Row = {};
  for (const key of writable) {
    if (body[key] !== undefined) out[key] = body[key];
  }
  return out;
}

export function crudRoutes<T extends PgTable>(opts: CrudOptions<T>) {
  const app = new Hono<AppEnv>();
  app.use("*", requireTenant);

  const present = opts.present ?? ((r: Row) => r);

  const after = async (orgId: string, row: Row, action: string) => {
    if (!opts.afterChange) return;
    try {
      await opts.afterChange(orgId, row, action);
    } catch (err) {
      // The database write already committed. Surfacing this loudly beats rolling back a
      // change the user was told succeeded.
      console.error(`[${opts.entityType}] afterChange failed:`, (err as Error).message);
    }
  };

  const scoped = (orgId: string, extra?: SQL) =>
    extra ? and(eq(opts.orgColumn, orgId), extra) : eq(opts.orgColumn, orgId);

  app.get("/", async (c) => {
    const rows = await db.select().from(opts.table as PgTable)
      .where(scoped(c.get("organizationId")));
    return c.json(rows.map((r) => present(r as Row)));
  });

  app.get("/:id", async (c) => {
    const [row] = await db.select().from(opts.table as PgTable)
      .where(scoped(c.get("organizationId"), eq(opts.idColumn, c.req.param("id"))));
    if (!row) return c.json({ error: "Not found" }, 404);
    return c.json(present(row as Row));
  });

  app.post("/", async (c) => {
    const organizationId = c.get("organizationId");
    const body = await c.req.json<Row>().catch(() => ({}) as Row);

    for (const field of opts.required ?? []) {
      if (body[field] === undefined || body[field] === null || body[field] === "") {
        return c.json({ error: `${field} is required` }, 400);
      }
    }
    if (opts.validate) {
      const problem = await opts.validate(body, organizationId);
      if (problem) return c.json({ error: problem }, 400);
    }

    const values = { ...pick(body, opts.writable), id: randomUUID(), organizationId };
    const inserted = (await db.insert(opts.table).values(values as never).returning()) as Row[];
    const row = inserted[0];
    if (!row) return c.json({ error: "Insert failed" }, 500);

    await after(organizationId, row, "create");
    await recordAudit(c, {
      action: "create",
      entityType: opts.entityType,
      entityId: row.id as string,
      after: row,
    });
    return c.json(present(row), 201);
  });

  app.patch("/:id", async (c) => {
    const organizationId = c.get("organizationId");
    const id = c.req.param("id");

    const [before] = await db.select().from(opts.table as PgTable)
      .where(scoped(organizationId, eq(opts.idColumn, id)));
    if (!before) return c.json({ error: "Not found" }, 404);

    const body = await c.req.json<Row>().catch(() => ({}) as Row);
    if (opts.validate) {
      const problem = await opts.validate(body, organizationId, before as Row);
      if (problem) return c.json({ error: problem }, 400);
    }

    const patch = pick(body, opts.writable);
    if (Object.keys(patch).length === 0) return c.json(present(before as Row));

    const updated = (await db.update(opts.table).set(patch as never)
      .where(scoped(organizationId, eq(opts.idColumn, id))).returning()) as Row[];
    const row = updated[0];
    if (!row) return c.json({ error: "Update failed" }, 500);

    await after(organizationId, row, "update");
    await recordAudit(c, {
      action: "update",
      entityType: opts.entityType,
      entityId: id,
      before: before as Row,
      after: row,
    });
    return c.json(present(row));
  });

  app.delete("/:id", async (c) => {
    const organizationId = c.get("organizationId");
    const id = c.req.param("id");

    const [before] = await db.select().from(opts.table as PgTable)
      .where(scoped(organizationId, eq(opts.idColumn, id)));
    if (!before) return c.json({ error: "Not found" }, 404);

    await db.delete(opts.table).where(scoped(organizationId, eq(opts.idColumn, id)));

    await after(organizationId, before as Row, "delete");
    await recordAudit(c, {
      action: "delete",
      entityType: opts.entityType,
      entityId: id,
      before: before as Row,
    });
    return c.body(null, 204);
  });

  return app;
}
