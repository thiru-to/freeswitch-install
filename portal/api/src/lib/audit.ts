/**
 * Audit logging.
 *
 * Every mutation goes through here. In a multi-tenant product this is the only thing that can
 * answer "why did our routing change at 2am", and it is the difference between a support
 * conversation and an argument.
 */
import { randomUUID } from "node:crypto";
import type { Context } from "hono";
import { db } from "../db";
import { auditLog } from "../db/schema";
import type { AppEnv } from "../middleware/tenant";

type AuditInput = {
  action: "create" | "update" | "delete" | string;
  entityType: string;
  entityId?: string;
  before?: unknown;
  after?: unknown;
  /**
   * For changes made without a user session - a feature code dialled from a handset, say.
   * `userId` stays null in that case (there is no portal user), so this is the only record of
   * who did it, and a change nobody remembers making is exactly the one that needs a name.
   */
  actor?: string;
  /** Required when there is no tenant middleware to read it from. */
  organizationId?: string;
};

/**
 * Strips anything that must never be written to an audit row. Ciphertext is still a secret,
 * and an audit log is read by more people than the table it describes.
 */
function redact(value: unknown): unknown {
  if (!value || typeof value !== "object") return value;
  const out: Record<string, unknown> = { ...(value as Record<string, unknown>) };
  for (const key of Object.keys(out)) {
    if (/passwordEnc|PinEnc|password|secret|ha1/i.test(key)) {
      out[key] = "[redacted]";
    }
  }
  return out;
}

export async function recordAudit(
  c: Context<AppEnv> | Context,
  input: AuditInput,
): Promise<void> {
  try {
    /* A machine route has no tenant middleware, so `get` returns undefined there and the
       explicit values are used instead. Typed loosely because a bare `Context` has no variable
       map at all, and the alternative is threading a second function through every caller. */
    const vars = c as Context<AppEnv>;
    const organizationId = input.organizationId ?? vars.get("organizationId");
    const userId = input.actor ? null : (vars.get("userId") ?? null);

    await db.insert(auditLog).values({
      id: randomUUID(),
      organizationId: organizationId ?? null,
      userId,
      action: input.actor ? `${input.action} (${input.actor})` : input.action,
      entityType: input.entityType,
      entityId: input.entityId ?? null,
      before: redact(input.before) ?? null,
      after: redact(input.after) ?? null,
      ipAddress:
        c.req.header("x-forwarded-for")?.split(",")[0]?.trim() ??
        c.req.header("x-real-ip") ??
        null,
      userAgent: c.req.header("user-agent") ?? null,
    });
  } catch (err) {
    // An audit write failing must not roll back the change the user already made - that would
    // be a worse outcome than a missing log line. Surface it loudly instead.
    console.error("[audit] failed to record:", (err as Error).message);
  }
}
