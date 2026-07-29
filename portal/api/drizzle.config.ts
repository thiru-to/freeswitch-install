import { defineConfig } from "drizzle-kit";

/**
 * DATABASE_URL is written into /opt/voip-api/.env by steps/41-api-deploy.sh, which builds it
 * from DB_HOST/DB_PORT in /etc/voip-pbx/config.env. For local work, put one in
 * portal/api/.env.
 */
const url = process.env.DATABASE_URL;
if (!url) {
  throw new Error(
    "DATABASE_URL is not set. The installer writes it to the API's .env; " +
      "for local work create portal/api/.env with a postgres:// URL.",
  );
}

export default defineConfig({
  dialect: "postgresql",
  /**
   * schema.ts re-exports auth-schema.ts, but drizzle-kit parses files rather than following
   * re-exports, so both are listed explicitly. Omitting the second silently produces
   * migrations with no auth tables.
   */
  schema: ["./src/db/schema.ts", "./src/db/auth-schema.ts"],
  out: "./drizzle",
  dbCredentials: { url },
  verbose: true,
  strict: true,
});
