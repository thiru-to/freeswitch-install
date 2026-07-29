CREATE TYPE "public"."attestation" AS ENUM('A', 'B', 'C');--> statement-breakpoint
CREATE TYPE "public"."call_direction" AS ENUM('inbound', 'outbound', 'internal');--> statement-breakpoint
CREATE TYPE "public"."destination_type" AS ENUM('extension', 'ring_group', 'ivr', 'voicemail', 'time_condition', 'queue', 'fax', 'external', 'hangup');--> statement-breakpoint
CREATE TYPE "public"."egress_mode" AS ENUM('direct', 'proxied');--> statement-breakpoint
CREATE TYPE "public"."fax_status" AS ENUM('received', 'failed', 'delivered');--> statement-breakpoint
CREATE TYPE "public"."recording_policy" AS ENUM('none', 'inbound', 'outbound', 'all');--> statement-breakpoint
CREATE TYPE "public"."ring_strategy" AS ENUM('simultaneous', 'sequential', 'random');--> statement-breakpoint
CREATE TYPE "public"."tenant_tier" AS ENUM('shared', 'dedicated');--> statement-breakpoint
CREATE TYPE "public"."sip_transport" AS ENUM('udp', 'tcp', 'tls');--> statement-breakpoint
CREATE TYPE "public"."trunk_auth_mode" AS ENUM('ip', 'register');--> statement-breakpoint
CREATE TABLE "audit_log" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text,
	"user_id" text,
	"action" text NOT NULL,
	"entity_type" text NOT NULL,
	"entity_id" text,
	"before" jsonb,
	"after" jsonb,
	"ip_address" text,
	"user_agent" text,
	"created_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "cdr" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"call_uuid" text NOT NULL,
	"correlation_id" text,
	"sip_call_id" text,
	"direction" "call_direction" NOT NULL,
	"caller_number" text,
	"caller_name" text,
	"destination_number" text NOT NULL,
	"extension_id" text,
	"trunk_id" text,
	"started_at" timestamp NOT NULL,
	"answered_at" timestamp,
	"ended_at" timestamp,
	"duration_sec" integer DEFAULT 0 NOT NULL,
	"billsec_sec" integer DEFAULT 0 NOT NULL,
	"hangup_cause" text,
	"recording_path" text,
	"attestation" text,
	"created_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "emergency_location" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"label" text NOT NULL,
	"street" text NOT NULL,
	"unit" text,
	"city" text NOT NULL,
	"region" text NOT NULL,
	"postal_code" text NOT NULL,
	"country" text DEFAULT 'US' NOT NULL,
	"callback_number" text,
	"validated_at" timestamp,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "extension" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"number" text NOT NULL,
	"display_name" text NOT NULL,
	"sip_password_enc" text NOT NULL,
	"voicemail_enabled" boolean DEFAULT true NOT NULL,
	"voicemail_pin_enc" text,
	"voicemail_email" text,
	"codec_prefs" text,
	"caller_id_name" text,
	"caller_id_number" text,
	"max_concurrent_calls" integer,
	"directory_cache_ms" integer,
	"emergency_location_id" text,
	"device_mac" text,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "fax" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"did_number" text NOT NULL,
	"caller_number" text,
	"caller_name" text,
	"deliver_to_email" text,
	"file_path" text,
	"pages" integer DEFAULT 0 NOT NULL,
	"status" "fax_status" DEFAULT 'received' NOT NULL,
	"failure_reason" text,
	"call_uuid" text,
	"received_at" timestamp DEFAULT now() NOT NULL,
	"delivered_at" timestamp
);
--> statement-breakpoint
CREATE TABLE "inbound_route" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"did_pattern" text NOT NULL,
	"description" text,
	"destination_type" "destination_type" NOT NULL,
	"destination_id" text,
	"priority" integer DEFAULT 10 NOT NULL,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "ivr_menu" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"number" text NOT NULL,
	"name" text NOT NULL,
	"greeting_sound" text,
	"invalid_sound" text,
	"timeout_sec" integer DEFAULT 5 NOT NULL,
	"max_retries" integer DEFAULT 3 NOT NULL,
	"timeout_type" "destination_type",
	"timeout_id" text,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "ivr_option" (
	"id" text PRIMARY KEY NOT NULL,
	"ivr_menu_id" text NOT NULL,
	"digit" text NOT NULL,
	"destination_type" "destination_type" NOT NULL,
	"destination_id" text,
	"description" text
);
--> statement-breakpoint
CREATE TABLE "outbound_route" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text,
	"name" text NOT NULL,
	"pattern" text NOT NULL,
	"trunk_id" text,
	"strip_digits" integer DEFAULT 0 NOT NULL,
	"prepend_digits" text,
	"caller_id_override" text,
	"priority" integer DEFAULT 10 NOT NULL,
	"is_emergency" boolean DEFAULT false NOT NULL,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "queue" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"number" text NOT NULL,
	"name" text NOT NULL,
	"strategy" text DEFAULT 'longest-idle-agent' NOT NULL,
	"moh_sound" text,
	"max_wait_sec" integer DEFAULT 300 NOT NULL,
	"timeout_type" "destination_type",
	"timeout_id" text,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "ring_group" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"number" text NOT NULL,
	"name" text NOT NULL,
	"strategy" "ring_strategy" DEFAULT 'simultaneous' NOT NULL,
	"ring_timeout_sec" integer DEFAULT 30 NOT NULL,
	"failover_type" "destination_type",
	"failover_id" text,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "ring_group_member" (
	"id" text PRIMARY KEY NOT NULL,
	"ring_group_id" text NOT NULL,
	"extension_id" text NOT NULL,
	"position" integer DEFAULT 0 NOT NULL,
	"delay_sec" integer DEFAULT 0 NOT NULL
);
--> statement-breakpoint
CREATE TABLE "tenant_settings" (
	"organization_id" text PRIMARY KEY NOT NULL,
	"sip_domain" text NOT NULL,
	"tier" "tenant_tier" DEFAULT 'shared' NOT NULL,
	"dispatcher_set_id" integer DEFAULT 1 NOT NULL,
	"egress_mode" "egress_mode" DEFAULT 'proxied' NOT NULL,
	"stir_shaken_enabled" boolean DEFAULT false NOT NULL,
	"stir_shaken_attest" "attestation" DEFAULT 'B' NOT NULL,
	"max_concurrent_calls" integer DEFAULT 10 NOT NULL,
	"recording_policy" "recording_policy" DEFAULT 'none' NOT NULL,
	"timezone" text DEFAULT 'Etc/UTC' NOT NULL,
	"default_caller_id_name" text,
	"default_caller_id_number" text,
	"emergency_notify_email" text,
	"emergency_notify_sms" text,
	"directory_cache_ms" integer DEFAULT 300000 NOT NULL,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "time_condition" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"name" text NOT NULL,
	"timezone" text DEFAULT 'Etc/UTC' NOT NULL,
	"rules" jsonb NOT NULL,
	"match_type" "destination_type",
	"match_id" text,
	"no_match_type" "destination_type",
	"no_match_id" text,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "trunk" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text,
	"name" text NOT NULL,
	"auth_mode" "trunk_auth_mode" DEFAULT 'ip' NOT NULL,
	"host" text NOT NULL,
	"port" integer DEFAULT 5060 NOT NULL,
	"transport" "sip_transport" DEFAULT 'udp' NOT NULL,
	"username" text,
	"password_enc" text,
	"from_domain" text,
	"codec_prefs" text,
	"priority" integer DEFAULT 10 NOT NULL,
	"carrier_signs" boolean DEFAULT false NOT NULL,
	"kam_gateway_id" integer,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "account" (
	"id" text PRIMARY KEY NOT NULL,
	"account_id" text NOT NULL,
	"provider_id" text NOT NULL,
	"user_id" text NOT NULL,
	"access_token" text,
	"refresh_token" text,
	"id_token" text,
	"access_token_expires_at" timestamp,
	"refresh_token_expires_at" timestamp,
	"scope" text,
	"password" text,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp NOT NULL
);
--> statement-breakpoint
CREATE TABLE "apikey" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text,
	"start" text,
	"prefix" text,
	"key" text NOT NULL,
	"user_id" text NOT NULL,
	"refill_interval" text,
	"refill_amount" text,
	"last_refill_at" timestamp,
	"enabled" boolean DEFAULT true NOT NULL,
	"rate_limit_enabled" boolean DEFAULT true NOT NULL,
	"rate_limit_time_window" text,
	"rate_limit_max" text,
	"request_count" text,
	"remaining" text,
	"last_request" timestamp,
	"expires_at" timestamp,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL,
	"permissions" text,
	"metadata" text
);
--> statement-breakpoint
CREATE TABLE "invitation" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"email" text NOT NULL,
	"role" text,
	"status" text DEFAULT 'pending' NOT NULL,
	"expires_at" timestamp NOT NULL,
	"inviter_id" text NOT NULL
);
--> statement-breakpoint
CREATE TABLE "member" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"user_id" text NOT NULL,
	"role" text DEFAULT 'member' NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "organization" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"slug" text NOT NULL,
	"logo" text,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"metadata" text,
	CONSTRAINT "organization_slug_unique" UNIQUE("slug")
);
--> statement-breakpoint
CREATE TABLE "session" (
	"id" text PRIMARY KEY NOT NULL,
	"expires_at" timestamp NOT NULL,
	"token" text NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp NOT NULL,
	"ip_address" text,
	"user_agent" text,
	"user_id" text NOT NULL,
	"active_organization_id" text,
	CONSTRAINT "session_token_unique" UNIQUE("token")
);
--> statement-breakpoint
CREATE TABLE "user" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"email" text NOT NULL,
	"email_verified" boolean DEFAULT false NOT NULL,
	"image" text,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "user_email_unique" UNIQUE("email")
);
--> statement-breakpoint
CREATE TABLE "verification" (
	"id" text PRIMARY KEY NOT NULL,
	"identifier" text NOT NULL,
	"value" text NOT NULL,
	"expires_at" timestamp NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "audit_log" ADD CONSTRAINT "audit_log_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "audit_log" ADD CONSTRAINT "audit_log_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "cdr" ADD CONSTRAINT "cdr_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "cdr" ADD CONSTRAINT "cdr_extension_id_extension_id_fk" FOREIGN KEY ("extension_id") REFERENCES "public"."extension"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "cdr" ADD CONSTRAINT "cdr_trunk_id_trunk_id_fk" FOREIGN KEY ("trunk_id") REFERENCES "public"."trunk"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "emergency_location" ADD CONSTRAINT "emergency_location_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "extension" ADD CONSTRAINT "extension_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "extension" ADD CONSTRAINT "extension_emergency_location_id_emergency_location_id_fk" FOREIGN KEY ("emergency_location_id") REFERENCES "public"."emergency_location"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "fax" ADD CONSTRAINT "fax_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "inbound_route" ADD CONSTRAINT "inbound_route_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ivr_menu" ADD CONSTRAINT "ivr_menu_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ivr_option" ADD CONSTRAINT "ivr_option_ivr_menu_id_ivr_menu_id_fk" FOREIGN KEY ("ivr_menu_id") REFERENCES "public"."ivr_menu"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "outbound_route" ADD CONSTRAINT "outbound_route_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "outbound_route" ADD CONSTRAINT "outbound_route_trunk_id_trunk_id_fk" FOREIGN KEY ("trunk_id") REFERENCES "public"."trunk"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "queue" ADD CONSTRAINT "queue_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ring_group" ADD CONSTRAINT "ring_group_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ring_group_member" ADD CONSTRAINT "ring_group_member_ring_group_id_ring_group_id_fk" FOREIGN KEY ("ring_group_id") REFERENCES "public"."ring_group"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ring_group_member" ADD CONSTRAINT "ring_group_member_extension_id_extension_id_fk" FOREIGN KEY ("extension_id") REFERENCES "public"."extension"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "tenant_settings" ADD CONSTRAINT "tenant_settings_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "time_condition" ADD CONSTRAINT "time_condition_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "trunk" ADD CONSTRAINT "trunk_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "account" ADD CONSTRAINT "account_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "apikey" ADD CONSTRAINT "apikey_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "invitation" ADD CONSTRAINT "invitation_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "invitation" ADD CONSTRAINT "invitation_inviter_id_user_id_fk" FOREIGN KEY ("inviter_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "member" ADD CONSTRAINT "member_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "member" ADD CONSTRAINT "member_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "session" ADD CONSTRAINT "session_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "audit_log_org_created_idx" ON "audit_log" USING btree ("organization_id","created_at");--> statement-breakpoint
CREATE INDEX "audit_log_entity_idx" ON "audit_log" USING btree ("entity_type","entity_id");--> statement-breakpoint
CREATE INDEX "cdr_org_started_idx" ON "cdr" USING btree ("organization_id","started_at");--> statement-breakpoint
CREATE INDEX "cdr_call_uuid_idx" ON "cdr" USING btree ("call_uuid");--> statement-breakpoint
CREATE INDEX "cdr_extension_idx" ON "cdr" USING btree ("extension_id");--> statement-breakpoint
CREATE INDEX "emergency_location_org_idx" ON "emergency_location" USING btree ("organization_id");--> statement-breakpoint
CREATE UNIQUE INDEX "extension_org_number_idx" ON "extension" USING btree ("organization_id","number");--> statement-breakpoint
CREATE INDEX "extension_org_idx" ON "extension" USING btree ("organization_id");--> statement-breakpoint
CREATE INDEX "extension_device_mac_idx" ON "extension" USING btree ("device_mac");--> statement-breakpoint
CREATE INDEX "fax_org_received_idx" ON "fax" USING btree ("organization_id","received_at");--> statement-breakpoint
CREATE INDEX "fax_did_idx" ON "fax" USING btree ("did_number");--> statement-breakpoint
CREATE INDEX "inbound_route_org_idx" ON "inbound_route" USING btree ("organization_id");--> statement-breakpoint
CREATE INDEX "inbound_route_did_idx" ON "inbound_route" USING btree ("did_pattern");--> statement-breakpoint
CREATE UNIQUE INDEX "ivr_menu_org_number_idx" ON "ivr_menu" USING btree ("organization_id","number");--> statement-breakpoint
CREATE UNIQUE INDEX "ivr_option_menu_digit_idx" ON "ivr_option" USING btree ("ivr_menu_id","digit");--> statement-breakpoint
CREATE INDEX "outbound_route_org_idx" ON "outbound_route" USING btree ("organization_id");--> statement-breakpoint
CREATE INDEX "outbound_route_priority_idx" ON "outbound_route" USING btree ("priority");--> statement-breakpoint
CREATE UNIQUE INDEX "queue_org_number_idx" ON "queue" USING btree ("organization_id","number");--> statement-breakpoint
CREATE UNIQUE INDEX "ring_group_org_number_idx" ON "ring_group" USING btree ("organization_id","number");--> statement-breakpoint
CREATE UNIQUE INDEX "ring_group_member_idx" ON "ring_group_member" USING btree ("ring_group_id","extension_id");--> statement-breakpoint
CREATE UNIQUE INDEX "tenant_settings_sip_domain_idx" ON "tenant_settings" USING btree ("sip_domain");--> statement-breakpoint
CREATE INDEX "time_condition_org_idx" ON "time_condition" USING btree ("organization_id");--> statement-breakpoint
CREATE INDEX "trunk_org_idx" ON "trunk" USING btree ("organization_id");--> statement-breakpoint
CREATE INDEX "account_user_id_idx" ON "account" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "apikey_user_id_idx" ON "apikey" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "invitation_organization_id_idx" ON "invitation" USING btree ("organization_id");--> statement-breakpoint
CREATE INDEX "member_organization_id_idx" ON "member" USING btree ("organization_id");--> statement-breakpoint
CREATE INDEX "member_user_id_idx" ON "member" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "session_user_id_idx" ON "session" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "verification_identifier_idx" ON "verification" USING btree ("identifier");