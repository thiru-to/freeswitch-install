/**
 * Fax post-processing.
 *
 * FreeSWITCH receives to TIFF because that is what T.30 transmits. Nobody wants a TIFF, so it
 * is converted to PDF and delivered - that conversion is the feature, not the receiving.
 */
import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { db } from "../db";
import { fax, tenantSettings } from "../db/schema";

export type FaxReport = {
  callUuid: string;
  domain: string;
  did: string;
  callerNumber?: string;
  callerName?: string;
  filePath: string;
  pages: number;
  status: "received" | "failed";
  failureReason?: string;
  remoteStationId?: string;
};

/**
 * TIFF to PDF via tiff2pdf (libtiff-tools).
 *
 * Returns null rather than throwing: a failed conversion must not lose the fax. The TIFF is
 * already on disk and the database row records where, so a conversion problem is recoverable
 * by hand where a thrown exception mid-transaction would not be.
 */
async function convertToPdf(tiffPath: string): Promise<string | null> {
  const pdfPath = tiffPath.replace(/\.tif{1,2}$/i, ".pdf");
  try {
    const proc = Bun.spawn(["tiff2pdf", "-o", pdfPath, tiffPath], {
      stdout: "pipe",
      stderr: "pipe",
    });
    await proc.exited;
    if (proc.exitCode !== 0) {
      const err = await new Response(proc.stderr).text();
      console.error(`[fax] tiff2pdf failed for ${tiffPath}: ${err.trim()}`);
      return null;
    }
    return pdfPath;
  } catch (err) {
    console.error(`[fax] tiff2pdf unavailable: ${(err as Error).message}`);
    return null;
  }
}

/**
 * Delivery by email.
 *
 * Uses the system MTA via `sendmail`. Debian installs none by default, so this is expected to
 * be absent on a fresh box - it warns rather than failing, because the fax is already stored
 * and downloadable from the portal. Install msmtp-mta or postfix to enable delivery.
 */
async function deliverByEmail(
  to: string,
  subject: string,
  body: string,
  attachment: { path: string; filename: string } | null,
): Promise<boolean> {
  const sendmail = Bun.which("sendmail");
  if (!sendmail) {
    console.warn(
      `[fax] no MTA installed - not delivering to ${to}. ` +
        `The fax is stored and available in the portal. Install msmtp-mta to enable email.`,
    );
    return false;
  }

  const boundary = `----voipfax-${randomUUID()}`;
  let message =
    `To: ${to}\r\nSubject: ${subject}\r\nMIME-Version: 1.0\r\n` +
    `Content-Type: multipart/mixed; boundary="${boundary}"\r\n\r\n` +
    `--${boundary}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n${body}\r\n`;

  if (attachment) {
    try {
      const bytes = await Bun.file(attachment.path).arrayBuffer();
      const b64 = Buffer.from(bytes).toString("base64").replace(/(.{76})/g, "$1\r\n");
      message +=
        `\r\n--${boundary}\r\nContent-Type: application/pdf\r\n` +
        `Content-Transfer-Encoding: base64\r\n` +
        `Content-Disposition: attachment; filename="${attachment.filename}"\r\n\r\n${b64}\r\n`;
    } catch (err) {
      console.error(`[fax] could not attach ${attachment.path}: ${(err as Error).message}`);
    }
  }
  message += `\r\n--${boundary}--\r\n`;

  try {
    const proc = Bun.spawn([sendmail, "-t"], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    proc.stdin.write(message);
    await proc.stdin.end();
    await proc.exited;
    return proc.exitCode === 0;
  } catch (err) {
    console.error(`[fax] sendmail failed: ${(err as Error).message}`);
    return false;
  }
}

/**
 * Records a received fax and delivers it.
 *
 * Writes the row FIRST, before conversion or delivery. A fax that arrived but whose PDF
 * conversion failed is a support ticket; a fax that arrived and left no trace is a lost
 * document, and the sender has no way to know.
 */
export async function recordInboundFax(report: FaxReport): Promise<string | null> {
  const tenant = await db.query.tenantSettings.findFirst({
    where: eq(tenantSettings.sipDomain, report.domain),
  });
  if (!tenant) {
    console.error(`[fax] no tenant for domain ${report.domain} - fax at ${report.filePath}`);
    return null;
  }

  const id = randomUUID();
  await db.insert(fax).values({
    id,
    organizationId: tenant.organizationId,
    didNumber: report.did,
    callerNumber: report.callerNumber ?? null,
    callerName: report.callerName ?? null,
    filePath: report.filePath,
    pages: report.pages,
    status: report.status,
    failureReason: report.failureReason ?? null,
    callUuid: report.callUuid,
  });

  if (report.status !== "received") {
    console.warn(
      `[fax] transfer failed on ${report.did}@${report.domain} from ${report.callerNumber}: ` +
        `${report.failureReason ?? "unknown"}`,
    );
    return id;
  }

  const pdf = await convertToPdf(report.filePath);
  if (pdf) {
    await db.update(fax).set({ filePath: pdf }).where(eq(fax.id, id));
  }

  const to = tenant.emergencyNotifyEmail ?? tenant.defaultCallerIdName ?? null;
  const recipient = report.callerNumber && to ? to : null;
  if (recipient && pdf) {
    const delivered = await deliverByEmail(
      recipient,
      `Fax received on ${report.did} (${report.pages} page${report.pages === 1 ? "" : "s"})`,
      `From: ${report.callerName || ""} ${report.callerNumber ?? "unknown"}\n` +
        `To: ${report.did}\nPages: ${report.pages}\n`,
      { path: pdf, filename: `fax-${report.did}-${Date.now()}.pdf` },
    );
    if (delivered) {
      await db.update(fax).set({ status: "delivered", deliveredAt: new Date() }).where(eq(fax.id, id));
    }
  }

  return id;
}
