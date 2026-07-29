/**
 * Encryption for the `*Enc` columns (SIP passwords, voicemail PINs, trunk credentials).
 *
 * AES-256-GCM: authenticated, so a tampered ciphertext fails to decrypt rather than silently
 * yielding garbage that then gets written into Kamailio's subscriber table.
 *
 * Plaintext SIP passwords never leave the API. The Kamailio projection decrypts here, computes
 * the HA1 digest, and stores only the digest - see services/kamailio-sync.ts.
 */
import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import { env } from "../env";

const ALGORITHM = "aes-256-gcm";
const IV_BYTES = 12; // GCM standard
const TAG_BYTES = 16;

/**
 * The configured key is an arbitrary-length secret from config.env, so hash it to exactly the
 * 32 bytes AES-256 requires rather than demanding the operator produce a 32-byte value.
 */
const key = createHash("sha256").update(env.encryptionKey).digest();

/** Returns `<iv>:<tag>:<ciphertext>`, all base64. Self-describing so the format can change. */
export function encrypt(plaintext: string): string {
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv(ALGORITHM, key, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `${iv.toString("base64")}:${tag.toString("base64")}:${ciphertext.toString("base64")}`;
}

export function decrypt(encoded: string): string {
  const parts = encoded.split(":");
  if (parts.length !== 3) {
    throw new Error("Ciphertext is not in the expected iv:tag:data form");
  }
  const [ivB64, tagB64, dataB64] = parts as [string, string, string];

  const decipher = createDecipheriv(ALGORITHM, key, Buffer.from(ivB64, "base64"));
  decipher.setAuthTag(Buffer.from(tagB64, "base64"));
  return Buffer.concat([
    decipher.update(Buffer.from(dataB64, "base64")),
    decipher.final(),
  ]).toString("utf8");
}

/**
 * SIP digest HA1 = MD5(username:realm:password).
 *
 * MD5 is not a choice - RFC 2617 digest authentication specifies it, and Kamailio's
 * `subscriber.ha1` column expects exactly this. It is not being used as a password hash.
 */
export function computeHa1(username: string, realm: string, password: string): string {
  return createHash("md5").update(`${username}:${realm}:${password}`).digest("hex");
}

/** HA1b variant, keyed on user@domain. Kamailio stores both for flexible auth. */
export function computeHa1b(username: string, realm: string, password: string): string {
  return createHash("md5")
    .update(`${username}@${realm}:${realm}:${password}`)
    .digest("hex");
}

/**
 * Generates a SIP password. Deliberately avoids characters that need escaping in SIP headers,
 * XML attributes or shell arguments - all three of which this value passes through.
 */
export function generateSipPassword(length = 24): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
  const bytes = randomBytes(length);
  let out = "";
  for (let i = 0; i < length; i++) {
    out += alphabet[bytes[i]! % alphabet.length];
  }
  return out;
}

/**
 * Generates a voicemail PIN.
 *
 * Digits only, because it is entered on a phone keypad - the SIP password cannot serve here
 * even though mod_voicemail will fall back to it, since an alphanumeric secret is untypable on
 * a handset and the mailbox is then simply unreachable.
 *
 * Rejects the two PINs a user would report as broken rather than as a coincidence: all-same
 * digits and the extension-shaped ascending run.
 */
export function generateVoicemailPin(length = 6): string {
  for (;;) {
    const bytes = randomBytes(length);
    let pin = "";
    for (let i = 0; i < length; i++) {
      pin += String(bytes[i]! % 10);
    }
    if (/^(\d)\1*$/.test(pin)) continue;
    if ("0123456789012345".includes(pin)) continue;
    return pin;
  }
}
