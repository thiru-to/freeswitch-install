/**
 * Authentication and tenancy.
 *
 * A tenant IS an organization. `session.activeOrganizationId` is the scope for every request,
 * and middleware/tenant.ts refuses to run a query without it.
 */
import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { organization } from "better-auth/plugins";
// Moved out of core in better-auth 1.6.x into its own first-party package.
import { apiKey } from "@better-auth/api-key";
import { createAccessControl } from "better-auth/plugins/access";
import { db } from "./db";
import * as schema from "./db/auth-schema";
import { env } from "./env";

/**
 * Permissions. Deliberately coarse: a PBX admin either manages telephony or does not. Finer
 * grained control is a support burden without a matching customer demand.
 *
 * `billing` and `security` are separated because they are the two a customer most often wants
 * to withhold from a general admin - CDR exports and trunk credentials respectively.
 */
const statement = {
  extension: ["create", "read", "update", "delete"],
  trunk: ["create", "read", "update", "delete"],
  route: ["create", "read", "update", "delete"],
  callflow: ["create", "read", "update", "delete"],
  cdr: ["read", "export"],
  recording: ["read", "delete"],
  tenant: ["read", "update"],
  audit: ["read"],
} as const;

const ac = createAccessControl(statement);

/** Read-only. For a support desk that must diagnose without being able to change routing. */
const viewer = ac.newRole({
  extension: ["read"],
  trunk: ["read"],
  route: ["read"],
  callflow: ["read"],
  cdr: ["read"],
  tenant: ["read"],
});

/** Day-to-day telephony administration, without trunk credentials or billing exports. */
const member = ac.newRole({
  extension: ["create", "read", "update", "delete"],
  trunk: ["read"],
  route: ["read"],
  callflow: ["create", "read", "update", "delete"],
  cdr: ["read"],
  recording: ["read"],
  tenant: ["read"],
});

const admin = ac.newRole({
  extension: ["create", "read", "update", "delete"],
  trunk: ["create", "read", "update", "delete"],
  route: ["create", "read", "update", "delete"],
  callflow: ["create", "read", "update", "delete"],
  cdr: ["read", "export"],
  recording: ["read", "delete"],
  tenant: ["read", "update"],
  audit: ["read"],
});

const owner = ac.newRole({
  extension: ["create", "read", "update", "delete"],
  trunk: ["create", "read", "update", "delete"],
  route: ["create", "read", "update", "delete"],
  callflow: ["create", "read", "update", "delete"],
  cdr: ["read", "export"],
  recording: ["read", "delete"],
  tenant: ["read", "update"],
  audit: ["read"],
});

export const auth = betterAuth({
  database: drizzleAdapter(db, { provider: "pg", schema }),

  secret: env.authSecret,
  baseURL: `https://${env.pbxFqdn}`,
  basePath: "/api/auth",

  emailAndPassword: {
    enabled: true,
    // Telephony admin credentials are worth more than a typical app login: a compromise means
    // toll fraud on someone else's bill.
    minPasswordLength: 12,
  },

  session: {
    expiresIn: 60 * 60 * 8,
    updateAge: 60 * 60,
    cookieCache: { enabled: true, maxAge: 60 * 5 },
  },

  trustedOrigins: [`https://${env.pbxFqdn}`],

  plugins: [
    organization({
      ac,
      roles: { owner, admin, member, viewer },
      allowUserToCreateOrganization: false, // tenants are provisioned, not self-served
      organizationLimit: 1,
      creatorRole: "owner",
      async sendInvitationEmail() {
        // Wired to a real transport alongside voicemail-to-email; until then invitations are
        // accepted via a link surfaced in the portal.
      },
    }),

    /**
     * Machine credentials, scoped to an organization. Used by the FreeSWITCH xml_curl gateway,
     * which must not authenticate as a human session.
     */
    apiKey({
      defaultPrefix: "voip_",
      enableMetadata: true,
    }),
  ],
});

export type Auth = typeof auth;
export type Session = Auth["$Infer"]["Session"];
