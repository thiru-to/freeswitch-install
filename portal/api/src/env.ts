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
} as const;

export type Env = typeof env;
