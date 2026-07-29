/**
 * VoIP PBX API.
 *
 * Binds loopback only — nginx terminates TLS and proxies in (steps/42-nginx.sh).
 */
import { Hono } from "hono";
import { logger } from "hono/logger";
import { auth } from "./auth";
import { env } from "./env";
import { cdrs } from "./routes/cdr";
import { extensions } from "./routes/extensions";
import { fsCdr } from "./routes/fs-cdr";
import { fsFeature } from "./routes/fs-feature";
import { fsXml } from "./routes/fs-xml";
import { tenants } from "./routes/tenants";
import { faxHook, faxes } from "./routes/fax";
import {
  inboundRoutes, ivrMenus, outboundRoutes, ringGroups, timeConditions, trunks,
} from "./routes/telephony";
import { ping as redisPing } from "./services/redis";
import { esl } from "./services/esl";
import { pool, db } from "./db";
import { tenantSettings } from "./db/schema";
import { rebuildTenant } from "./services/cache";

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
// fax_receive.lua reports completed receives here, with the same machine credential.
app.route("/fs/fax", faxHook);
// mod_xml_cdr posts here on hangup. Off the call path - the caller has already gone.
app.route("/fs/cdr", fsCdr);
// Feature codes dialled from a handset. Narrow by design - see the route.
app.route("/fs/feature", fsFeature);

app.route("/api/tenant", tenants);
app.route("/api/extensions", extensions);
app.route("/api/faxes", faxes);
app.route("/api/trunks", trunks);
app.route("/api/inbound-routes", inboundRoutes);
app.route("/api/outbound-routes", outboundRoutes);
app.route("/api/ring-groups", ringGroups);
app.route("/api/ivr-menus", ivrMenus);
app.route("/api/time-conditions", timeConditions);
app.route("/api/cdr", cdrs);

app.notFound((c) => c.json({ error: "Not found" }, 404));

app.onError((err, c) => {
  console.error("[api] unhandled:", err);
  // Never leak internals to a client; the detail is in the journal.
  return c.json({ error: "Internal error" }, 500);
});

/**
 * Warm the cache on startup.
 *
 * Redis is configured as a pure cache (`save ""`, `appendonly no` in steps/21-redis.sh), so a
 * Redis restart loses every key. Nothing else rebuilds them: the write-through path only fires
 * on a config change, so without this the cache stays empty until someone happens to edit
 * something, and every lookup takes the slow fall-through path in the meantime.
 *
 * Deliberately non-fatal and not awaited. A cold cache is a performance problem, not a
 * correctness one - the fall-through chain still resolves - so failing to warm must not stop
 * the API from serving.
 */
async function warmCache(): Promise<void> {
  try {
    const tenants = await db.query.tenantSettings.findMany();
    for (const tenant of tenants) {
      await rebuildTenant(tenant.organizationId);
    }
    console.log(`[cache] warmed ${tenants.length} tenant(s)`);
  } catch (err) {
    console.warn("[cache] warm failed (serving from the fallback path):", (err as Error).message);
  }
}

void warmCache();

export default {
  port: env.port,
  hostname: env.host,
  fetch: app.fetch,
};
