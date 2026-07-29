#!/usr/bin/env bun
/**
 * Provision a tenant.
 *
 * Organizations are deliberately not self-served (`allowUserToCreateOrganization: false` in
 * auth.ts) - a tenant is a commercial relationship, and letting any signed-up user mint one
 * would also let them claim a SIP domain. This is the platform-operator path that replaces it.
 *
 * It does the whole job, because a half-provisioned tenant looks fine in the portal and fails
 * on the wire: organization, owner membership, telephony settings, Kamailio's domain table,
 * and the Redis cache the Lua handler reads.
 *
 *   bun run src/cli/provision-tenant.ts \
 *     --name "Acme Corp" --slug acme --domain acme.example.com --owner admin@acme.test
 */
import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { db } from "../db";
import { member, organization, tenantSettings, user } from "../db/schema";
import { rebuildTenant } from "../services/cache";
import { reloadKamailio, syncDomain } from "../services/kamailio-sync";

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 ? process.argv[i + 1] : undefined;
}

const name = arg("name");
const slug = arg("slug");
const domain = arg("domain");
const ownerEmail = arg("owner");
const tier = (arg("tier") ?? "shared") as "shared" | "dedicated";
const maxCalls = Number(arg("max-calls") ?? "10");

if (!name || !slug || !domain || !ownerEmail) {
  console.error(
    "Usage: provision-tenant.ts --name <name> --slug <slug> --domain <sip-domain> " +
      "--owner <email> [--tier shared|dedicated] [--max-calls N]",
  );
  process.exit(2);
}

const owner = await db.query.user.findFirst({ where: eq(user.email, ownerEmail) });
if (!owner) {
  console.error(`No user with email ${ownerEmail}. They must sign up first.`);
  process.exit(1);
}

// The SIP domain is the tenancy boundary, so it is unique platform-wide: two tenants sharing
// one would make use_domain=1 stop distinguishing them.
const clash = await db.query.tenantSettings.findFirst({
  where: eq(tenantSettings.sipDomain, domain),
});
if (clash) {
  console.error(`SIP domain ${domain} is already used by organization ${clash.organizationId}.`);
  process.exit(1);
}

const existing = await db.query.organization.findFirst({ where: eq(organization.slug, slug) });
const orgId = existing?.id ?? randomUUID();

if (!existing) {
  await db.insert(organization).values({ id: orgId, name, slug, createdAt: new Date() });
  console.log(`  created organization ${slug} (${orgId})`);
} else {
  console.log(`  organization ${slug} already exists (${orgId})`);
}

const membership = await db.query.member.findFirst({ where: eq(member.organizationId, orgId) });
if (!membership) {
  await db.insert(member).values({
    id: randomUUID(),
    organizationId: orgId,
    userId: owner.id,
    role: "owner",
    createdAt: new Date(),
  });
  console.log(`  ${ownerEmail} is owner`);
}

await db
  .insert(tenantSettings)
  .values({
    organizationId: orgId,
    sipDomain: domain,
    tier,
    dispatcherSetId: 1,
    maxConcurrentCalls: maxCalls,
  })
  .onConflictDoUpdate({
    target: tenantSettings.organizationId,
    set: { sipDomain: domain, tier, maxConcurrentCalls: maxCalls },
  });
console.log(`  telephony configured: ${domain} (${tier}, max ${maxCalls} concurrent)`);

// Kamailio must know the domain before anyone in it can register.
await syncDomain(domain);
await reloadKamailio();
await rebuildTenant(orgId);
console.log(`  Kamailio domain registered and cache warmed`);

console.log(`\nProvisioned ${name} <${domain}>`);
process.exit(0);
