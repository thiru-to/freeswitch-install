/**
 * CDR ingest from mod_xml_cdr.
 *
 * Separate from the fs/xml gateway because the failure modes are opposite. The XML gateway is
 * on the call path and must answer fast or fail; this is off it entirely - FreeSWITCH posts
 * after the caller has hung up - so here it is durability that matters and latency that does
 * not.
 *
 * Same shared secret as the XML gateway, since both are FreeSWITCH talking to us over loopback
 * and a second credential to rotate buys nothing.
 */
import { Hono } from "hono";
import { ingestCdr } from "../services/cdr";

export const fsCdr = new Hono();

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

fsCdr.use("*", async (c, next) => {
  const expected = process.env.FS_XML_GATEWAY_SECRET;
  // Fail closed. CDRs name tenants and dialled numbers; an open endpoint both leaks that shape
  // and lets anyone forge billing records.
  if (!expected) return c.text("FS_XML_GATEWAY_SECRET is not configured", 500);

  const header = c.req.header("Authorization") ?? "";
  const [scheme, encoded] = header.split(" ");
  if (scheme !== "Basic" || !encoded) return c.text("Unauthorized", 401);

  const [, password] = Buffer.from(encoded, "base64").toString("utf8").split(":");
  if (!password || !safeEqual(password, expected)) return c.text("Unauthorized", 401);

  await next();
});

fsCdr.post("/", async (c) => {
  /* mod_xml_cdr posts either raw text/xml (encode=textxml) or the document in a `cdr` form
     field (the default url-encoded mode). Accepting both means the encode setting can change
     without the ingest silently storing nothing. */
  const contentType = c.req.header("Content-Type") ?? "";
  let xml: string;
  if (contentType.includes("xml")) {
    xml = await c.req.text();
  } else {
    const form = await c.req.parseBody();
    xml = String(form["cdr"] ?? "");
  }

  if (!xml) return c.text("empty CDR", 400);

  try {
    const result = await ingestCdr(xml);
    if (!result.stored) {
      /* 200, not 4xx, and deliberately so: mod_xml_cdr retries anything that is not a 2xx, and
         a CDR we cannot attribute will not become attributable on the tenth attempt. Retrying
         it for ever costs FreeSWITCH a worker and buries the real failures. The record is
         logged here and, because err-log-dir is configured, kept on disk by FreeSWITCH too. */
      console.warn(`[cdr] not stored: ${result.reason}`);
      return c.text(`ignored: ${result.reason}`, 200);
    }
    return c.text("OK", 200);
  } catch (err) {
    // A genuine failure - database down, constraint violation we did not anticipate. 500 tells
    // FreeSWITCH to retry, which is what we want for something transient.
    console.error(`[cdr] ingest failed: ${(err as Error).message}`);
    return c.text("ingest failed", 500);
  }
});
