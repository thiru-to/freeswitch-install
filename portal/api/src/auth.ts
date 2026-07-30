/**
 * Authentication and tenancy.
 *
 * A tenant IS an organization. `session.activeOrganizationId` is the scope for every request,
 * and middleware/tenant.ts refuses to run a query without it.
 */
import { betterAuth } from "better-auth";
import { APIError } from "better-auth/api";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { organization } from "better-auth/plugins";
// Moved out of core in better-auth 1.6.x into its own first-party package.
import { apiKey } from "@better-auth/api-key";
import { createAccessControl } from "better-auth/plugins/access";
import { db } from "./db";
import * as schema from "./db/auth-schema";
import { env } from "./env";
import { consumeSignupPermission } from "./lib/signup-gate";

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

/**
 * The roles, exported so middleware can enforce them.
 *
 * Exported deliberately rather than duplicated: these definitions were decorative for a while -
 * every role was declared here in detail and then never consulted, so a `viewer` could create
 * trunks, set carrier credentials and delete extensions. middleware/tenant.ts checks against
 * THIS object, so the statement above is the one and only description of who may do what.
 */
export const ROLES = { owner, admin, member, viewer } as const;
export type RoleName = keyof typeof ROLES;

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

  /**
   * No self-service registration. See lib/signup-gate.ts for why this is a hook rather than
   * `emailAndPassword.disableSignUp` - that option would also block the operator CLI, since it
   * is enforced in the same handler `auth.api.signUpEmail()` calls.
   *
   * This is the application-layer control. steps/42-nginx.sh also returns 404 for the signup
   * path, so the endpoint is not reachable from the internet at all; this catches anything that
   * reaches the API directly on loopback.
   */
  databaseHooks: {
    user: {
      create: {
        before: async (newUser) => {
          if (!consumeSignupPermission()) {
            console.warn(`[auth] rejected signup attempt for ${newUser.email}`);
            throw new APIError("BAD_REQUEST", {
              message: "Registration is not open. Accounts are created by the operator.",
            });
          }
          return { data: newUser };
        },
      },
    },
  },

  session: {
    expiresIn: 60 * 60 * 8,
    updateAge: 60 * 60,
    cookieCache: { enabled: true, maxAge: 60 * 5 },
  },

  trustedOrigins: [`https://${env.pbxFqdn}`],

  /**
   * Where to find the real client address behind nginx.
   *
   * Without this, better-auth logs "Rate limiting could not determine a client IP" and falls
   * back to ONE shared bucket per path - which is worse than no limiter, because a single
   * attacker exhausts the bucket and locks every legitimate user out of signing in.
   *
   * `x-real-ip`, NOT `x-forwarded-for`. nginx sets X-Forwarded-For with
   * `$proxy_add_x_forwarded_for`, which APPENDS to whatever the client sent, so a client can
   * prepend a fake address and be rate-limited as that instead. X-Real-IP is assigned from
   * `$remote_addr` and overwrites, so it cannot be spoofed. See /etc/nginx/proxy_params,
   * written by steps/42-nginx.sh.
   */
  advanced: {
    ipAddress: {
      ipAddressHeaders: ["x-real-ip"],
    },
  },

  /**
   * Second layer under nginx's `limit_req zone=api_auth` (5r/m per source address), which is the
   * primary brute-force control. This one still matters: it is the only limiter in front of the
   * API when something reaches it directly on loopback, and it is keyed per-path so sign-in gets
   * a tighter budget than everything else.
   */
  rateLimit: {
    enabled: true,
    window: 60,
    max: 60,
    customRules: {
      "/sign-in/email": { window: 300, max: 10 },
      "/forget-password": { window: 300, max: 5 },
    },
  },

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
