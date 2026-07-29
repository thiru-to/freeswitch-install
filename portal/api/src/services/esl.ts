/**
 * FreeSWITCH Event Socket client.
 *
 * Minimal by design. The published Node ESL libraries are unmaintained and pull in a
 * dependency tree for what is a line-oriented protocol over TCP; this covers the commands we
 * actually issue - `api`, and specifically `xml_flush_cache`.
 *
 * ESL listens on 127.0.0.1:8021 only (see steps/31-freeswitch-config.sh). It is a full
 * remote-control channel for the switch, which is why it is loopback-bound with a generated
 * password rather than exposed.
 */
import { env } from "../env";

type EslResult = { ok: boolean; body: string };

/**
 * One command per connection. ESL supports long-lived connections with event subscriptions,
 * but everything we do is request/response, and a per-command socket cannot get wedged in a
 * half-authenticated state the way a pooled one can.
 */
async function eslCommand(command: string, timeoutMs = 5000): Promise<EslResult> {
  if (!env.fsEslPassword) {
    return { ok: false, body: "FS_ESL_PASSWORD is not set" };
  }

  return new Promise<EslResult>((resolve) => {
    let buffer = "";
    let authenticated = false;
    let settled = false;

    const finish = (result: EslResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        socket?.end();
      } catch {
        /* already closing */
      }
      resolve(result);
    };

    const timer = setTimeout(
      () => finish({ ok: false, body: `ESL command timed out after ${timeoutMs}ms` }),
      timeoutMs,
    );

    let socket: { write: (s: string) => void; end: () => void } | undefined;

    Bun.connect({
      hostname: env.fsEslHost,
      port: env.fsEslPort,
      socket: {
        open(sock) {
          socket = sock;
        },
        data(sock, chunk) {
          buffer += chunk.toString();

          // FreeSWITCH greets with an auth request before accepting anything.
          if (!authenticated && buffer.includes("auth/request")) {
            authenticated = true;
            buffer = "";
            sock.write(`auth ${env.fsEslPassword}\n\n`);
            return;
          }

          // Once authenticated, the +OK for auth is followed by our command's reply.
          if (authenticated && buffer.includes("+OK accepted") && !buffer.includes("api/response")) {
            buffer = "";
            sock.write(`api ${command}\n\n`);
            return;
          }

          if (buffer.includes("-ERR invalid")) {
            finish({ ok: false, body: "ESL authentication rejected" });
            return;
          }

          // A complete api response carries Content-Length; wait for the whole body.
          const match = buffer.match(/Content-Length:\s*(\d+)\r?\n\r?\n([\s\S]*)$/);
          if (match) {
            const expected = Number(match[1]);
            const body = match[2] ?? "";
            if (Buffer.byteLength(body) >= expected) {
              finish({ ok: true, body: body.trim() });
            }
          }
        },
        error(_sock, err) {
          finish({ ok: false, body: `ESL socket error: ${err.message}` });
        },
        close() {
          finish({ ok: false, body: "ESL connection closed before a reply" });
        },
      },
    }).catch((err: Error) => finish({ ok: false, body: `ESL connect failed: ${err.message}` }));
  });
}

export const esl = {
  /** Runs an arbitrary API command. Returns ok=false rather than throwing. */
  api: eslCommand,

  /**
   * Clears FreeSWITCH's directory cache.
   *
   * This is what makes an aggressive `cacheable` TTL safe: an edit takes effect immediately
   * instead of waiting out the TTL. Without arguments it flushes everything; with them it
   * flushes one user.
   */
  async flushXmlCache(user?: string, domain?: string): Promise<boolean> {
    const cmd =
      user && domain ? `xml_flush_cache id ${user} ${domain}` : "xml_flush_cache";
    const { ok, body } = await eslCommand(cmd);
    if (!ok) {
      // Not fatal: Redis is already updated and the TTL will expire. Log so a persistently
      // unreachable FreeSWITCH is visible rather than silently serving stale directory data.
      console.warn(`[esl] ${cmd} failed: ${body}`);
    }
    return ok;
  },

  /**
   * Short default timeout: this is called by /health, and a health check that blocks for
   * seconds is read as an outage by monitoring. FreeSWITCH on loopback answers in
   * milliseconds or it is not answering at all.
   */
  async status(timeoutMs = 1000): Promise<EslResult> {
    return eslCommand("status", timeoutMs);
  },

  /** Live channel count, for the portal dashboard. */
  async showCalls(): Promise<EslResult> {
    return eslCommand("show calls count");
  },
};
