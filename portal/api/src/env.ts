/**
 * Environment, validated once at startup.
 *
 * These are written into /opt/voip-api/.env by steps/41-api-deploy.sh, which builds them from
 * /etc/voip-pbx/config.env. Failing loudly here beats a null-reference three layers deep on
 * the first call.
 */

function required(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(
      `Missing required environment variable ${name}. ` +
        `The installer writes these to ${process.env.API_DIR ?? "/opt/voip-api"}/.env; ` +
        `for local work create portal/api/.env.`,
    );
  }
  return v;
}

function optional(name: string, fallback: string): string {
  return process.env[name] ?? fallback;
}

export const env = {
  nodeEnv: optional("NODE_ENV", "development"),
  isProduction: optional("NODE_ENV", "development") === "production",

  host: optional("HOST", "127.0.0.1"),
  port: Number(optional("PORT", "3000")),

  databaseUrl: required("DATABASE_URL"),
  redisUrl: optional("REDIS_URL", "redis://127.0.0.1:6379"),

  fsEslHost: optional("FS_ESL_HOST", "127.0.0.1"),
  fsEslPort: Number(optional("FS_ESL_PORT", "8021")),
  fsEslPassword: optional("FS_ESL_PASSWORD", ""),

  pbxFqdn: optional("PBX_FQDN", "localhost"),
  pbxSipDomain: optional("PBX_SIP_DOMAIN", "localhost"),

  /**
   * Key for the `*Enc` columns. Distinct from the auth secret: rotating a session secret
   * should not make every stored SIP password undecryptable.
   */
  encryptionKey: required("ENCRYPTION_KEY"),
  authSecret: required("AUTH_SECRET"),

  /** Kamailio's database, which we project into. Separate from ours by design. */
  kamailioDatabaseUrl: optional("KAMAILIO_DATABASE_URL", ""),

  /**
   * Sender for fax and voicemail notifications.
   *
   * Must be an address on a domain we control, with SPF and DKIM - never the tenant's SIP
   * domain or the caller's number. This one sender covers every tenant, so alignment is the
   * only thing keeping the mail out of spam folders.
   */
  mailFrom: optional("SMTP_FROM", `pbx@${optional("PBX_FQDN", "localhost")}`),
  mailFromName: optional("MAIL_FROM_NAME", "Phone System"),
  mailReplyTo: optional("MAIL_REPLY_TO", ""),
} as const;

export type Env = typeof env;
