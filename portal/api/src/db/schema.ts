/**
 * Application schema for the multi-tenant PBX.
 *
 * Tenancy: a tenant IS a better-auth `organization`. Every table here carries
 * `organizationId`, and the tenant middleware scopes every query by the session's
 * `activeOrganizationId`. Isolation is enforced in the API layer rather than by Postgres RLS
 * - the API is the only writer, and RLS at this scale buys complexity rather than safety.
 *
 * Relationship to Kamailio's own database: Kamailio owns its schema (created by kamdbctl) in
 * a SEPARATE database. Nothing here lives there. The API projects a subset of these tables
 * into Kamailio's operational tables (`subscriber`, `address`, `dispatcher`, `dr_gateways`,
 * `dr_rules`) - see services/kamailio-sync.ts. That projection is one-way: this schema is the
 * source of truth and Kamailio's tables are derived.
 *
 * Secrets: columns suffixed `Enc` hold ciphertext, encrypted by the API with a key from
 * /etc/voip-pbx/config.env. Plaintext SIP passwords never leave the API - the Kamailio
 * projection decrypts, computes the HA1 digest, and writes only that.
 */
import { relations } from "drizzle-orm";
import {
  pgTable,
  pgEnum,
  text,
  integer,
  boolean,
  timestamp,
  jsonb,
  uniqueIndex,
  index,
} from "drizzle-orm/pg-core";
import { organization, user } from "./auth-schema";

export * from "./auth-schema";

/* ---------------------------------------------------------------------------------------
 * Enumerations
 * ------------------------------------------------------------------------------------ */

/** Shared pool (tenant = SIP domain) or pinned to a dedicated FreeSWITCH node set. */
export const tenantTierEnum = pgEnum("tenant_tier", ["shared", "dedicated"]);

/**
 * Whether outbound calls leave via Kamailio's egress path. `proxied` is the only mode that
 * can carry a STIR/SHAKEN Identity header, because FreeSWITCH has no signing module.
 */
export const egressModeEnum = pgEnum("egress_mode", ["direct", "proxied"]);

/**
 * Attestation asserted on signed calls. Claiming A for traffic you cannot actually vouch for
 * is a compliance problem, not a configuration shortcut, so the default is B.
 */
export const attestationEnum = pgEnum("attestation", ["A", "B", "C"]);

/** Carriers authenticate by source IP; smaller providers want us to register to them. */
export const trunkAuthModeEnum = pgEnum("trunk_auth_mode", ["ip", "register"]);

export const transportEnum = pgEnum("sip_transport", ["udp", "tcp", "tls"]);

/**
 * Anywhere a call can be sent. Used by inbound routes, IVR options, ring-group failover and
 * time conditions, so a destination is expressed uniformly wherever one is needed.
 */
export const destinationTypeEnum = pgEnum("destination_type", [
  "extension",
  "ring_group",
  "ivr",
  "voicemail",
  "time_condition",
  "queue",
  "fax",
  "external",
  "hangup",
]);

export const ringStrategyEnum = pgEnum("ring_strategy", [
  "simultaneous",
  "sequential",
  "random",
]);

export const recordingPolicyEnum = pgEnum("recording_policy", [
  "none",
  "inbound",
  "outbound",
  "all",
]);

export const callDirectionEnum = pgEnum("call_direction", [
  "inbound",
  "outbound",
  "internal",
]);

/* ---------------------------------------------------------------------------------------
 * Tenant configuration
 * ------------------------------------------------------------------------------------ */

export const tenantSettings = pgTable(
  "tenant_settings",
  {
    organizationId: text("organization_id")
      .primaryKey()
      .references(() => organization.id, { onDelete: "cascade" }),

    /**
     * The tenant's SIP domain. This is the tenancy boundary at the SIP layer: Kamailio runs
     * with use_domain=1, so user@domainA and user@domainB are different subscribers and a
     * call cannot cross tenants by accident.
     */
    sipDomain: text("sip_domain").notNull(),

    tier: tenantTierEnum("tier").default("shared").notNull(),

    /**
     * Which Kamailio dispatcher set carries this tenant's calls. Shared tenants use set 1; a
     * dedicated tenant gets its own set. That is what keeps the two commercial tiers as one
     * architecture rather than two.
     */
    dispatcherSetId: integer("dispatcher_set_id").default(1).notNull(),

    egressMode: egressModeEnum("egress_mode").default("proxied").notNull(),

    stirShakenEnabled: boolean("stir_shaken_enabled").default(false).notNull(),
    stirShakenAttest: attestationEnum("stir_shaken_attest").default("B").notNull(),

    /**
     * Toll-fraud ceiling. A stolen SIP credential is monetised by placing many simultaneous
     * international calls, so this cap is the difference between a handful of calls plus an
     * alert and a five-figure overnight bill.
     */
    maxConcurrentCalls: integer("max_concurrent_calls").default(10).notNull(),

    recordingPolicy: recordingPolicyEnum("recording_policy").default("none").notNull(),
    timezone: text("timezone").default("Etc/UTC").notNull(),

    defaultCallerIdName: text("default_caller_id_name"),
    defaultCallerIdNumber: text("default_caller_id_number"),

    /**
     * E911 (Kari's Law): someone on site must be notified when 911 is dialled. Not optional
     * in the US. The notification fires from the ESL event handler.
     */
    emergencyNotifyEmail: text("emergency_notify_email"),
    emergencyNotifySms: text("emergency_notify_sms"),

    /**
     * How long FreeSWITCH may cache a directory lookup for this tenant, in milliseconds.
     * Emitted as the `cacheable` attribute on the xml_curl directory response; FreeSWITCH
     * core honours it in switch_xml_locate_user_merged. 0 disables caching. The portal calls
     * `xml_flush_cache` on write, so a long TTL does not delay config changes.
     */
    directoryCacheMs: integer("directory_cache_ms").default(300000).notNull(),

    enabled: boolean("enabled").default(true).notNull(),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .defaultNow()
      .$onUpdate(() => new Date())
      .notNull(),
  },
  (table) => [uniqueIndex("tenant_settings_sip_domain_idx").on(table.sipDomain)],
);

/* ---------------------------------------------------------------------------------------
 * E911
 * ------------------------------------------------------------------------------------ */

/**
 * Dispatchable location, per RAY BAUM'S Act. A civic address precise enough for responders
 * to find the caller - which in a multi-floor office means floor and room, not just street.
 */
export const emergencyLocation = pgTable(
  "emergency_location",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),

    label: text("label").notNull(),
    street: text("street").notNull(),
    unit: text("unit"),
    city: text("city").notNull(),
    region: text("region").notNull(),
    postalCode: text("postal_code").notNull(),
    country: text("country").default("US").notNull(),

    /** Number responders call back on if the call drops. */
    callbackNumber: text("callback_number"),

    /**
     * Set when the carrier has accepted the address. An unvalidated location is a compliance
     * gap, so the portal surfaces it rather than letting it sit unnoticed.
     */
    validatedAt: timestamp("validated_at"),

    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .defaultNow()
      .$onUpdate(() => new Date())
      .notNull(),
  },
  (table) => [index("emergency_location_org_idx").on(table.organizationId)],
);

/* ---------------------------------------------------------------------------------------
 * Extensions
 * ------------------------------------------------------------------------------------ */

export const extension = pgTable(
  "extension",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),

    number: text("number").notNull(),
    displayName: text("display_name").notNull(),

    /**
     * Ciphertext. The Kamailio projection decrypts this, computes HA1, and stores only the
     * digest in Kamailio's subscriber table. Never returned by the API.
     */
    sipPasswordEnc: text("sip_password_enc").notNull(),

    voicemailEnabled: boolean("voicemail_enabled").default(true).notNull(),
    voicemailPinEnc: text("voicemail_pin_enc"),
    voicemailEmail: text("voicemail_email"),

    /** Overrides the tenant default. Opus first for WiFi/mobile, G.711 for PSTN interop. */
    codecPrefs: text("codec_prefs"),

    callerIdName: text("caller_id_name"),
    callerIdNumber: text("caller_id_number"),

    /** Null means inherit the tenant ceiling. */
    maxConcurrentCalls: integer("max_concurrent_calls"),

    /**
     * Per-extension override of tenantSettings.directoryCacheMs. Set to 0 to force a fresh
     * lookup on every registration, which is useful while debugging one endpoint.
     */
    directoryCacheMs: integer("directory_cache_ms"),

    emergencyLocationId: text("emergency_location_id").references(
      () => emergencyLocation.id,
      { onDelete: "set null" },
    ),

    /** For MAC-based provisioning (roadmap R7). */
    deviceMac: text("device_mac"),

    enabled: boolean("enabled").default(true).notNull(),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .defaultNow()
      .$onUpdate(() => new Date())
      .notNull(),
  },
  (table) => [
    /**
     * An extension number is unique within a tenant, not globally - two tenants may both
     * have extension 100, and that is the whole point of domain-based multi-tenancy.
     */
    uniqueIndex("extension_org_number_idx").on(table.organizationId, table.number),
    index("extension_org_idx").on(table.organizationId),
    index("extension_device_mac_idx").on(table.deviceMac),
  ],
);

/* ---------------------------------------------------------------------------------------
 * Trunks and routing
 * ------------------------------------------------------------------------------------ */

export const trunk = pgTable(
  "trunk",
  {
    id: text("id").primaryKey(),
    /** Null means a platform-wide carrier available to every tenant. */
    organizationId: text("organization_id").references(() => organization.id, {
      onDelete: "cascade",
    }),

    name: text("name").notNull(),
    authMode: trunkAuthModeEnum("auth_mode").default("ip").notNull(),

    host: text("host").notNull(),
    port: integer("port").default(5060).notNull(),
    transport: transportEnum("transport").default("udp").notNull(),

    /** Only for authMode = register. */
    username: text("username"),
    passwordEnc: text("password_enc"),
    fromDomain: text("from_domain"),

    codecPrefs: text("codec_prefs"),

    /** Lower wins. Drives least-cost ordering across carriers. */
    priority: integer("priority").default(10).notNull(),

    /**
     * The carrier signs STIR/SHAKEN on our behalf, so we do not need to. Many wholesale
     * ITSPs do this for SMB resellers, and it removes the STI-CA procurement entirely.
     */
    carrierSigns: boolean("carrier_signs").default(false).notNull(),

    /** Set by kamailio-sync when this trunk is projected into Kamailio's dr_gateways. */
    kamGatewayId: integer("kam_gateway_id"),

    enabled: boolean("enabled").default(true).notNull(),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .defaultNow()
      .$onUpdate(() => new Date())
      .notNull(),
  },
  (table) => [index("trunk_org_idx").on(table.organizationId)],
);

export const inboundRoute = pgTable(
  "inbound_route",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),

    /** The DID in E.164, or a pattern covering a range. */
    didPattern: text("did_pattern").notNull(),
    description: text("description"),

    destinationType: destinationTypeEnum("destination_type").notNull(),
    /** Row id of the destination, or a literal number when type is `external`. */
    destinationId: text("destination_id"),

    priority: integer("priority").default(10).notNull(),
    enabled: boolean("enabled").default(true).notNull(),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .defaultNow()
      .$onUpdate(() => new Date())
      .notNull(),
  },
  (table) => [
    index("inbound_route_org_idx").on(table.organizationId),
    /** The dialplan looks up by DID on every inbound call, so this index is on the call path. */
    index("inbound_route_did_idx").on(table.didPattern),
  ],
);

export const outboundRoute = pgTable(
  "outbound_route",
  {
    id: text("id").primaryKey(),
    /** Null means a platform default available to every tenant. */
    organizationId: text("organization_id").references(() => organization.id, {
      onDelete: "cascade",
    }),

    name: text("name").notNull(),
    /** Regex matched against the dialled number. */
    pattern: text("pattern").notNull(),

    trunkId: text("trunk_id").references(() => trunk.id, { onDelete: "cascade" }),

    /** Digit manipulation applied before handing the call to the carrier. */
    stripDigits: integer("strip_digits").default(0).notNull(),
    prependDigits: text("prepend_digits"),

    callerIdOverride: text("caller_id_override"),

    /** Lower wins; drives least-cost routing and failover order. */
    priority: integer("priority").default(10).notNull(),

    /**
     * Emergency routes are matched BEFORE fraud checks, time conditions and route
     * permissions, and bypass all of them. A 911 call blocked by our own toll-fraud cap is
     * the worst failure this system could have, so this flag is load-bearing.
     */
    isEmergency: boolean("is_emergency").default(false).notNull(),

    enabled: boolean("enabled").default(true).notNull(),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .defaultNow()
      .$onUpdate(() => new Date())
      .notNull(),
  },
  (table) => [
    index("outbound_route_org_idx").on(table.organizationId),
    index("outbound_route_priority_idx").on(table.priority),
  ],
);

/* ---------------------------------------------------------------------------------------
 * Call handling features
 * ------------------------------------------------------------------------------------ */

export const ringGroup = pgTable(
  "ring_group",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),

    number: text("number").notNull(),
    name: text("name").notNull(),
    strategy: ringStrategyEnum("strategy").default("simultaneous").notNull(),
    ringTimeoutSec: integer("ring_timeout_sec").default(30).notNull(),

    /** Where the call goes if nobody answers. */
    failoverType: destinationTypeEnum("failover_type"),
    failoverId: text("failover_id"),

    enabled: boolean("enabled").default(true).notNull(),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .defaultNow()
      .$onUpdate(() => new Date())
      .notNull(),
  },
  (table) => [
    uniqueIndex("ring_group_org_number_idx").on(table.organizationId, table.number),
  ],
);

export const ringGroupMember = pgTable(
  "ring_group_member",
  {
    id: text("id").primaryKey(),
    ringGroupId: text("ring_group_id")
      .notNull()
      .references(() => ringGroup.id, { onDelete: "cascade" }),
    extensionId: text("extension_id")
      .notNull()
      .references(() => extension.id, { onDelete: "cascade" }),
    /** Ring order for the sequential strategy; ignored for simultaneous. */
    position: integer("position").default(0).notNull(),
    /** Per-member delay, so a manager's phone can start ringing after the team's. */
    delaySec: integer("delay_sec").default(0).notNull(),
  },
  (table) => [
    uniqueIndex("ring_group_member_idx").on(table.ringGroupId, table.extensionId),
  ],
);

export const ivrMenu = pgTable(
  "ivr_menu",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),

    number: text("number").notNull(),
    name: text("name").notNull(),

    greetingSound: text("greeting_sound"),
    invalidSound: text("invalid_sound"),
    timeoutSec: integer("timeout_sec").default(5).notNull(),
    maxRetries: integer("max_retries").default(3).notNull(),

    /** Where the caller goes after exhausting retries or timing out. */
    timeoutType: destinationTypeEnum("timeout_type"),
    timeoutId: text("timeout_id"),

    enabled: boolean("enabled").default(true).notNull(),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .defaultNow()
      .$onUpdate(() => new Date())
      .notNull(),
  },
  (table) => [
    uniqueIndex("ivr_menu_org_number_idx").on(table.organizationId, table.number),
  ],
);

export const ivrOption = pgTable(
  "ivr_option",
  {
    id: text("id").primaryKey(),
    ivrMenuId: text("ivr_menu_id")
      .notNull()
      .references(() => ivrMenu.id, { onDelete: "cascade" }),
    /** The DTMF digit, or "*" / "#". */
    digit: text("digit").notNull(),
    destinationType: destinationTypeEnum("destination_type").notNull(),
    destinationId: text("destination_id"),
    description: text("description"),
  },
  (table) => [uniqueIndex("ivr_option_menu_digit_idx").on(table.ivrMenuId, table.digit)],
);

export const timeCondition = pgTable(
  "time_condition",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),

    name: text("name").notNull(),
    /**
     * Evaluated in this zone, not the server's. A tenant in another timezone must get their
     * own business hours rather than ours.
     */
    timezone: text("timezone").default("Etc/UTC").notNull(),

    /**
     * Match rules, evaluated by the Lua handler at call time. Shape:
     *   [{ "days": [1,2,3,4,5], "start": "09:00", "end": "17:00" },
     *    { "date": "2026-12-25", "allDay": true, "invert": true }]
     * JSON rather than columns because the rule shapes are heterogeneous and are always read
     * as a unit by a single consumer.
     */
    rules: jsonb("rules").notNull(),

    matchType: destinationTypeEnum("match_type"),
    matchId: text("match_id"),
    noMatchType: destinationTypeEnum("no_match_type"),
    noMatchId: text("no_match_id"),

    enabled: boolean("enabled").default(true).notNull(),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .defaultNow()
      .$onUpdate(() => new Date())
      .notNull(),
  },
  (table) => [index("time_condition_org_idx").on(table.organizationId)],
);

/**
 * Call queues. mod_callcenter is already built; the portal UI and agent handling are roadmap
 * R11. The table exists now so enabling it later is configuration rather than a migration.
 */
export const queue = pgTable(
  "queue",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),

    number: text("number").notNull(),
    name: text("name").notNull(),
    strategy: text("strategy").default("longest-idle-agent").notNull(),
    mohSound: text("moh_sound"),
    maxWaitSec: integer("max_wait_sec").default(300).notNull(),

    timeoutType: destinationTypeEnum("timeout_type"),
    timeoutId: text("timeout_id"),

    enabled: boolean("enabled").default(true).notNull(),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .defaultNow()
      .$onUpdate(() => new Date())
      .notNull(),
  },
  (table) => [uniqueIndex("queue_org_number_idx").on(table.organizationId, table.number)],
);

/* ---------------------------------------------------------------------------------------
 * Records
 * ------------------------------------------------------------------------------------ */

/**
 * Call detail records. Written by the API from FreeSWITCH CDR plus Kamailio `acc`, because
 * neither source carries tenant attribution on its own - Kamailio knows the SIP domain,
 * FreeSWITCH knows the channel variables, and only we know which organization that is.
 */
export const cdr = pgTable(
  "cdr",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),

    /** FreeSWITCH channel UUID. */
    callUuid: text("call_uuid").notNull(),
    /**
     * Ties the four SIP legs of one sandwiched call together. Without it a single call is
     * four unlinked legs in a packet capture and troubleshooting is miserable.
     */
    correlationId: text("correlation_id"),
    sipCallId: text("sip_call_id"),

    direction: callDirectionEnum("direction").notNull(),

    callerNumber: text("caller_number"),
    callerName: text("caller_name"),
    destinationNumber: text("destination_number").notNull(),

    extensionId: text("extension_id").references(() => extension.id, {
      onDelete: "set null",
    }),
    trunkId: text("trunk_id").references(() => trunk.id, { onDelete: "set null" }),

    startedAt: timestamp("started_at").notNull(),
    answeredAt: timestamp("answered_at"),
    endedAt: timestamp("ended_at"),
    durationSec: integer("duration_sec").default(0).notNull(),
    /** Billable seconds - answer to hangup, which is what an invoice is built from. */
    billsecSec: integer("billsec_sec").default(0).notNull(),

    hangupCause: text("hangup_cause"),
    recordingPath: text("recording_path"),

    /** STIR/SHAKEN verification result inbound, attestation asserted outbound. */
    attestation: text("attestation"),

    createdAt: timestamp("created_at").defaultNow().notNull(),
  },
  (table) => [
    index("cdr_org_started_idx").on(table.organizationId, table.startedAt),
    /**
     * UNIQUE, and load-bearing rather than an optimisation. mod_xml_cdr retries a post it
     * believes failed, so without this a slow or restarting API turns one call into several
     * billing rows. The ingest relies on this constraint for its ON CONFLICT DO NOTHING.
     */
    uniqueIndex("cdr_call_uuid_idx").on(table.callUuid),
    index("cdr_extension_idx").on(table.extensionId),
  ],
);

export const faxStatusEnum = pgEnum("fax_status", [
  "received",
  "failed",
  "delivered",
]);

/**
 * Inbound faxes. mod_spandsp receives to TIFF; the API converts to PDF and emails it, which is
 * the feature an SMB actually wants - a raw T.38 endpoint is not.
 *
 * Fax over IP is fragile: a B2BUA plus two rtpengine relays is the hard case for T.38, so
 * `pages` and `status` exist to make partial failures visible rather than silent.
 */
export const fax = pgTable(
  "fax",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),

    /** The DID it arrived on. */
    didNumber: text("did_number").notNull(),
    callerNumber: text("caller_number"),
    callerName: text("caller_name"),

    /** Where the PDF is delivered. Falls back to the tenant default when null. */
    deliverToEmail: text("deliver_to_email"),

    filePath: text("file_path"),
    pages: integer("pages").default(0).notNull(),
    status: faxStatusEnum("status").default("received").notNull(),
    /** spandsp's result string when a transfer fails part-way. */
    failureReason: text("failure_reason"),

    callUuid: text("call_uuid"),
    receivedAt: timestamp("received_at").defaultNow().notNull(),
    deliveredAt: timestamp("delivered_at"),
  },
  (table) => [
    index("fax_org_received_idx").on(table.organizationId, table.receivedAt),
    index("fax_did_idx").on(table.didNumber),
  ],
);

/**
 * Who changed what. Non-negotiable for a multi-tenant product: when a customer asks why their
 * routing changed at 2am, this is the only thing that can answer.
 */
export const auditLog = pgTable(
  "audit_log",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id").references(() => organization.id, {
      onDelete: "cascade",
    }),
    /** Null for platform-level actions taken without a user session. */
    userId: text("user_id").references(() => user.id, { onDelete: "set null" }),

    action: text("action").notNull(),
    entityType: text("entity_type").notNull(),
    entityId: text("entity_id"),

    /** Full before/after, so a change can be reconstructed or reverted. */
    before: jsonb("before"),
    after: jsonb("after"),

    ipAddress: text("ip_address"),
    userAgent: text("user_agent"),
    createdAt: timestamp("created_at").defaultNow().notNull(),
  },
  (table) => [
    index("audit_log_org_created_idx").on(table.organizationId, table.createdAt),
    index("audit_log_entity_idx").on(table.entityType, table.entityId),
  ],
);

/* ---------------------------------------------------------------------------------------
 * Relations
 * ------------------------------------------------------------------------------------ */

export const tenantSettingsRelations = relations(tenantSettings, ({ one }) => ({
  organization: one(organization, {
    fields: [tenantSettings.organizationId],
    references: [organization.id],
  }),
}));

export const extensionRelations = relations(extension, ({ one, many }) => ({
  organization: one(organization, {
    fields: [extension.organizationId],
    references: [organization.id],
  }),
  emergencyLocation: one(emergencyLocation, {
    fields: [extension.emergencyLocationId],
    references: [emergencyLocation.id],
  }),
  ringGroupMemberships: many(ringGroupMember),
}));

export const emergencyLocationRelations = relations(emergencyLocation, ({ many }) => ({
  extensions: many(extension),
}));

export const trunkRelations = relations(trunk, ({ many }) => ({
  outboundRoutes: many(outboundRoute),
}));

export const outboundRouteRelations = relations(outboundRoute, ({ one }) => ({
  trunk: one(trunk, { fields: [outboundRoute.trunkId], references: [trunk.id] }),
}));

export const ringGroupRelations = relations(ringGroup, ({ many }) => ({
  members: many(ringGroupMember),
}));

export const ringGroupMemberRelations = relations(ringGroupMember, ({ one }) => ({
  ringGroup: one(ringGroup, {
    fields: [ringGroupMember.ringGroupId],
    references: [ringGroup.id],
  }),
  extension: one(extension, {
    fields: [ringGroupMember.extensionId],
    references: [extension.id],
  }),
}));

export const ivrMenuRelations = relations(ivrMenu, ({ many }) => ({
  options: many(ivrOption),
}));

export const ivrOptionRelations = relations(ivrOption, ({ one }) => ({
  menu: one(ivrMenu, { fields: [ivrOption.ivrMenuId], references: [ivrMenu.id] }),
}));

export const cdrRelations = relations(cdr, ({ one }) => ({
  extension: one(extension, { fields: [cdr.extensionId], references: [extension.id] }),
  trunk: one(trunk, { fields: [cdr.trunkId], references: [trunk.id] }),
}));
