/**
 * Database connection.
 *
 * One pool for the application database. Kamailio's database is reached separately by
 * services/kamailio-sync.ts, deliberately: they are different schemas with different owners
 * and mixing them in one pool invites accidental cross-writes.
 */
import { drizzle } from "drizzle-orm/node-postgres";
import pg from "pg";
import { env } from "../env";
import * as schema from "./schema";

/**
 * Sized for the API, not the database. Postgres is configured with max_connections=200 in
 * steps/20-postgresql.sh; leaving headroom matters because Kamailio and FreeSWITCH hold
 * connections of their own.
 */
export const pool = new pg.Pool({
  connectionString: env.databaseUrl,
  max: 20,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});

pool.on("error", (err) => {
  // An idle client erroring is survivable - the pool replaces it. Crashing the API over it
  // would drop every in-flight request for no reason.
  console.error("[db] idle client error:", err.message);
});

export const db = drizzle(pool, { schema });

export type Db = typeof db;
export { schema };
