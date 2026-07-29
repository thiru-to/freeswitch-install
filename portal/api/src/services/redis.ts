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
  /** Call-flow objects, read by the Lua scripts mid-call. */
  ringGroup: (domain: string, id: string) => `voip:rg:${domain}:${id}`,
  ivr: (domain: string, id: string) => `voip:ivr:${domain}:${id}`,
  timeCondition: (domain: string, id: string) => `voip:tc:${domain}:${id}`,
  /** Prefix used when clearing everything for one tenant. */
  tenantPrefix: (domain: string) => `voip:*:${domain}*`,
} as const;

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
