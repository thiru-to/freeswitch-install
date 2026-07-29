/**
 * Projection into Kamailio's database.
 *
 * Kamailio owns its own schema, created by kamdbctl, in a SEPARATE database. This schema is the
 * source of truth; Kamailio's tables are derived. The projection is deliberately one-way — if
 * these ever disagree, ours wins and a rebuild fixes it.
 *
 * A separate pool from db/index.ts, on purpose: different database, different credentials, and
 * keeping them apart makes an accidental cross-schema write impossible rather than merely
 * unlikely.
 */
import pg from "pg";
import { env } from "../env";
import { computeHa1, computeHa1b } from "../lib/crypto";
import type { extension as extensionTable, trunk as trunkTable } from "../db/schema";

type ExtensionRow = typeof extensionTable.$inferSelect;
type TrunkRow = typeof trunkTable.$inferSelect;

let pool: pg.Pool | null = null;

function getPool(): pg.Pool | null {
  if (!env.kamailioDatabaseUrl) return null;
  if (!pool) {
    pool = new pg.Pool({
      connectionString: env.kamailioDatabaseUrl,
      max: 5,
      connectionTimeoutMillis: 5_000,
    });
    pool.on("error", (err) => console.error("[kamailio-sync] pool error:", err.message));
  }
  return pool;
}

/**
 * Writes a subscriber Kamailio can authenticate.
 *
 * Only the HA1 digests are stored — never the plaintext password. Kamailio is configured with
 * `calculate_ha1=yes` against these columns, and the SIP realm is the tenant's domain, which is
 * what makes user@tenantA and user@tenantB distinct credentials.
 */
export async function syncSubscriber(
  ext: ExtensionRow,
  sipDomain: string,
  plaintextPassword: string,
): Promise<boolean> {
  const p = getPool();
  if (!p) {
    console.warn("[kamailio-sync] KAMAILIO_DATABASE_URL not set — subscriber not projected");
    return false;
  }

  const ha1 = computeHa1(ext.number, sipDomain, plaintextPassword);
  const ha1b = computeHa1b(ext.number, sipDomain, plaintextPassword);

  try {
    await p.query(
      `INSERT INTO subscriber (username, domain, password, ha1, ha1b)
       VALUES ($1, $2, '', $3, $4)
       ON CONFLICT (username, domain)
       DO UPDATE SET ha1 = EXCLUDED.ha1, ha1b = EXCLUDED.ha1b, password = ''`,
      [ext.number, sipDomain, ha1, ha1b],
    );
    return true;
  } catch (err) {
    console.error(`[kamailio-sync] subscriber ${ext.number}@${sipDomain}:`, (err as Error).message);
    return false;
  }
}

export async function removeSubscriber(username: string, sipDomain: string): Promise<boolean> {
  const p = getPool();
  if (!p) return false;
  try {
    await p.query(`DELETE FROM subscriber WHERE username = $1 AND domain = $2`, [
      username,
      sipDomain,
    ]);
    // Drop live registrations too, or a deleted extension stays reachable until its
    // registration expires.
    await p.query(`DELETE FROM location WHERE username = $1 AND domain = $2`, [
      username,
      sipDomain,
    ]);
    return true;
  } catch (err) {
    console.error(`[kamailio-sync] remove ${username}@${sipDomain}:`, (err as Error).message);
    return false;
  }
}

/**
 * Registers the tenant's SIP domain with Kamailio's `domain` module, which is what makes
 * multi-tenancy work: `use_domain=1` means lookups are scoped by it.
 */
export async function syncDomain(sipDomain: string): Promise<boolean> {
  const p = getPool();
  if (!p) return false;
  try {
    await p.query(
      `INSERT INTO domain (domain, did) VALUES ($1, $1) ON CONFLICT (domain) DO NOTHING`,
      [sipDomain],
    );
    return true;
  } catch (err) {
    console.error(`[kamailio-sync] domain ${sipDomain}:`, (err as Error).message);
    return false;
  }
}

/**
 * A carrier that authenticates by source IP goes in the `address` table, which the permissions
 * module reads. steps/14-responsive-firewall.sh reads the same table, so the proxy and the
 * firewall cannot disagree about who is a trunk.
 */
export async function syncTrunkAddress(trunk: TrunkRow): Promise<boolean> {
  const p = getPool();
  if (!p || trunk.authMode !== "ip") return false;
  try {
    await p.query(
      `INSERT INTO address (grp, ip_addr, mask, port, tag)
       VALUES (1, $1, 32, $2, $3)
       ON CONFLICT DO NOTHING`,
      [trunk.host, trunk.port, trunk.id],
    );
    return true;
  } catch (err) {
    console.error(`[kamailio-sync] trunk address ${trunk.host}:`, (err as Error).message);
    return false;
  }
}

export async function removeTrunkAddress(trunkId: string): Promise<boolean> {
  const p = getPool();
  if (!p) return false;
  try {
    await p.query(`DELETE FROM address WHERE tag = $1`, [trunkId]);
    return true;
  } catch (err) {
    console.error(`[kamailio-sync] remove trunk address:`, (err as Error).message);
    return false;
  }
}

/**
 * Tells Kamailio to re-read the tables it caches in memory.
 *
 * `permissions` and `dispatcher` both hold their data in memory and will not notice a database
 * write on their own. Without this, a trunk added in the portal is invisible until restart.
 *
 * Uses kamcmd over the binrpc control socket rather than an HTTP RPC port, so nothing extra is
 * exposed. Best-effort: a failure here means stale in-memory data, not a broken write.
 */
export async function reloadKamailio(): Promise<boolean> {
  try {
    const proc = Bun.spawn(["kamcmd", "permissions.addressReload"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    await proc.exited;
    const dispatcher = Bun.spawn(["kamcmd", "dispatcher.reload"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    await dispatcher.exited;
    return proc.exitCode === 0;
  } catch (err) {
    console.warn("[kamailio-sync] kamcmd reload failed:", (err as Error).message);
    return false;
  }
}
