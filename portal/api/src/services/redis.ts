/**
 * Redis client.
 *
 * Bun ships a native RedisClient, so no third-party dependency. This is the same Redis the
 * FreeSWITCH Lua handler reads from via mod_hiredis - the API writes, Lua reads.
 *
 * Key namespace (Lua depends on these exact shapes, so changing one means changing
 * scripts/xml_handler.lua too):
 *
 *   voip:dir:<domain>:<user>     rendered directory XML for one extension
 *   voip:routes:<domain>         the tenant's outbound route table, JSON
 *   voip:did:<domain>:<number>   inbound DID destination, JSON
 *   voip:tenant:<domain>         tenant settings needed at call time, JSON
 *   voip:num:<domain>:<number>   internal feature number -> call-flow object, JSON
 *   voip:call:<domain>:<number>  per-extension call handling (DND, forwarding), JSON
 *   voip:rg:<domain>:<id>        ring group with its members
 *   voip:ivr:<domain>:<id>       IVR menu with its options, keyed by digit
 *   voip:tc:<domain>:<id>        time condition with its rules
 */
import { RedisClient } from "bun";
import { env } from "../env";

export const redis = new RedisClient(env.redisUrl);

export const keys = {
  directory: (domain: string, user: string) => `voip:dir:${domain}:${user}`,
  routes: (domain: string) => `voip:routes:${domain}`,
  did: (domain: string, number: string) => `voip:did:${domain}:${number}`,
  tenant: (domain: string) => `voip:tenant:${domain}`,
  /**
   * Internal feature number -> call-flow object. Users expect to dial 600 for the sales ring
   * group or 700 for the auto-attendant from their own desk phone, exactly as they would dial
   * a colleague's extension. Without this map an internally dialled 600 is not an extension
   * and not a DID, so it falls through to the outbound routes and dies as UNALLOCATED_NUMBER.
   */
  featureNumber: (domain: string, number: string) => `voip:num:${domain}:${number}`,
  /**
   * How to treat a call TO this extension - DND, forwarding, ring time, call waiting.
   *
   * Separate from the directory entry because the two are read by different consumers asking
   * different questions. The directory is rendered XML that FreeSWITCH's own user lookup
   * consumes, and it describes the *caller* when they originate; this describes what to do
   * when someone dials them. Making the dialplan parse XML out of the directory entry to find
   * a DND flag would be a poor trade for one saved key.
   */
  extensionCall: (domain: string, number: string) => `voip:call:${domain}:${number}`,
  /** Call-flow objects, read by the Lua scripts mid-call. */
  ringGroup: (domain: string, id: string) => `voip:rg:${domain}:${id}`,
  ivr: (domain: string, id: string) => `voip:ivr:${domain}:${id}`,
  timeCondition: (domain: string, id: string) => `voip:tc:${domain}:${id}`,
  /**
   * Every per-tenant key pattern, for a full purge before a rebuild.
   *
   * Enumerated rather than globbed as `voip:*:<domain>*`, because that trailing wildcard would
   * also match a tenant whose domain merely starts with this one - `acme.test` would wipe
   * `acme.test.evil.com`. A colon-terminated prefix cannot straddle a domain boundary, and any
   * new key shape must be added here or it will survive a rebuild as a ghost.
   */
  tenantPatterns: (domain: string) => [
    `voip:dir:${domain}:*`,
    `voip:did:${domain}:*`,
    `voip:num:${domain}:*`,
    `voip:call:${domain}:*`,
    `voip:rg:${domain}:*`,
    `voip:ivr:${domain}:*`,
    `voip:tc:${domain}:*`,
    `voip:routes:${domain}`,
    `voip:tenant:${domain}`,
  ],
} as const;

/**
 * Deletes every key matching a pattern, via SCAN rather than KEYS.
 *
 * KEYS blocks the whole server for the length of the scan, and this Redis is on the call path -
 * a config change in the portal must never stall call setup for another tenant.
 */
export async function safeDelPattern(pattern: string): Promise<number> {
  let cursor = "0";
  let deleted = 0;
  try {
    do {
      const reply = (await redis.send("SCAN", [cursor, "MATCH", pattern, "COUNT", "200"])) as [
        string,
        string[],
      ];
      cursor = reply[0];
      const batch = reply[1];
      if (batch.length > 0) {
        await redis.del(...batch);
        deleted += batch.length;
      }
    } while (cursor !== "0");
  } catch (err) {
    console.error(`[redis] scan-delete ${pattern} failed:`, (err as Error).message);
  }
  return deleted;
}

/**
 * Redis is on the call path via Lua, but the API's own writes are not. A failed cache write
 * must not fail the config change that triggered it - the data is already committed to
 * Postgres, and Lua's Postgres fallback will serve correct results until the cache catches up.
 */
export async function safeSet(key: string, value: string, ttlSeconds?: number): Promise<boolean> {
  try {
    if (ttlSeconds) {
      await redis.set(key, value, "EX", ttlSeconds);
    } else {
      await redis.set(key, value);
    }
    return true;
  } catch (err) {
    console.error(`[redis] set ${key} failed:`, (err as Error).message);
    return false;
  }
}

export async function safeDel(...keysToDelete: string[]): Promise<boolean> {
  if (keysToDelete.length === 0) return true;
  try {
    await redis.del(...keysToDelete);
    return true;
  } catch (err) {
    console.error(`[redis] del failed:`, (err as Error).message);
    return false;
  }
}

export async function ping(): Promise<boolean> {
  try {
    return (await redis.send("PING", [])) === "PONG";
  } catch {
    return false;
  }
}
