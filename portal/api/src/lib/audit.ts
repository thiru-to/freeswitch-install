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

export async function recordAudit(c: Context<AppEnv>, input: AuditInput): Promise<void> {
  try {
    await db.insert(auditLog).values({
      id: randomUUID(),
      organizationId: c.get("organizationId"),
      userId: c.get("userId"),
      action: input.action,
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
