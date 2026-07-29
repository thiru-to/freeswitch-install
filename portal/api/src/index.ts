/**
 * VoIP PBX API.
 *
 * Binds loopback only — nginx terminates TLS and proxies in (steps/42-nginx.sh).
 */
import { Hono } from "hono";
import { logger } from "hono/logger";
import { auth } from "./auth";
import { env } from "./env";
import { extensions } from "./routes/extensions";
import { fsXml } from "./routes/fs-xml";
import { tenants } from "./routes/tenants";
import { ping as redisPing } from "./services/redis";
import { esl } from "./services/esl";
import { pool } from "./db";

const app = new Hono();

app.use("*", logger());

/**
 * Bounds a probe with its own deadline.
 *
 * The pools' normal timeouts are tuned for real work (Postgres allows 5s to connect), which is
 * far too long for a health check — a monitor polling every 5s reads a slow answer as an
 * outage. Each probe gets a short budget of its own, and "did not answer in time" is reported
 * as unhealthy, which is what it means operationally.
 */
function probe(p: Promise<boolean>, ms = 750): Promise<boolean> {
  return Promise.race([
    p.catch(() => false),
    new Promise<boolean>((resolve) => setTimeout(() => resolve(false), ms)),
  ]);
}

/**
 * Health, for steps/52-monitoring.sh. Reports each dependency separately: "the API is up but
 * Redis is unreachable" is a materially different situation from "everything is fine", and a
 * single boolean hides exactly the case worth paging on.
 */
app.get("/health", async (c) => {
  const [dbOk, redisOk, eslOk] = await Promise.all([
    probe(pool.query("SELECT 1").then(() => true)),
    probe(redisPing()),
    probe(esl.status(750).then((r) => r.ok)),
  ]);

  const healthy = dbOk && redisOk;
  return c.json(
    {
      status: healthy ? "ok" : "degraded",
      database: dbOk,
      redis: redisOk,
      // ESL being down means the portal cannot see live calls or flush the XML cache, but
      // config changes still land in Postgres and Redis - degraded, not unhealthy.
      freeswitch: eslOk,
    },
    healthy ? 200 : 503,
  );
});

// better-auth owns /api/auth/** including the organization endpoints.
app.on(["GET", "POST"], "/api/auth/*", (c) => auth.handler(c.req.raw));

// The FreeSWITCH XML fallback. Machine-authenticated, not a user session.
app.route("/fs/xml", fsXml);

app.route("/api/tenant", tenants);
app.route("/api/extensions", extensions);

app.notFound((c) => c.json({ error: "Not found" }, 404));

app.onError((err, c) => {
  console.error("[api] unhandled:", err);
  // Never leak internals to a client; the detail is in the journal.
  return c.json({ error: "Internal error" }, 500);
});

export default {
  port: env.port,
  hostname: env.host,
  fetch: app.fetch,
};
