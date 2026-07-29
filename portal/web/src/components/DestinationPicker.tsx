/**
 * Picks the polymorphic destination used by inbound routes, IVR options, ring-group failover
 * and both branches of a time condition.
 *
 * Two fields that must agree, which is exactly the pair the API validates together: a type
 * naming a row plus an id belonging to another tenant is rejected server-side. Presenting them
 * as one control means the second field is always a list of things this tenant actually owns,
 * so the rejectable combination is not reachable by clicking - the server check stays the
 * boundary, this just stops people running into it.
 */
import { Group, Select, Stack, TextInput } from "@mantine/core";
import { useQuery } from "@tanstack/react-query";
import {
  DESTINATION_NEEDS_ROW,
  endpoints,
  type DestinationType,
} from "../lib/api";

const TYPE_OPTIONS: { value: DestinationType; label: string }[] = [
  { value: "extension", label: "Extension" },
  { value: "ring_group", label: "Ring group" },
  { value: "ivr", label: "IVR menu" },
  { value: "time_condition", label: "Time condition" },
  { value: "voicemail", label: "Voicemail" },
  { value: "fax", label: "Fax" },
  { value: "external", label: "External number" },
  { value: "hangup", label: "Hang up" },
];

export type DestinationValue = {
  type: DestinationType | null;
  id: string | null;
};

export function DestinationPicker({
  label,
  value,
  onChange,
  allowNone = true,
  description,
}: {
  label: string;
  value: DestinationValue;
  onChange: (next: DestinationValue) => void;
  allowNone?: boolean;
  description?: string;
}) {
  // Enabled only when a row-backed type is selected, so picking "Hang up" does not fire three
  // list queries that nothing will read.
  const needsRow = value.type ? DESTINATION_NEEDS_ROW.includes(value.type) : false;

  // Also enabled for `voicemail`, which is not a row-backed type - its id is a mailbox number -
  // but still wants the extension list to choose from.
  const extensions = useQuery({
    queryKey: ["extensions"],
    queryFn: endpoints.extensions,
    enabled: value.type === "extension" || value.type === "voicemail",
  });
  const ringGroups = useQuery({
    queryKey: ["ring-groups"],
    queryFn: endpoints.ringGroups,
    enabled: needsRow && value.type === "ring_group",
  });
  const ivrMenus = useQuery({
    queryKey: ["ivr-menus"],
    queryFn: endpoints.ivrMenus,
    enabled: needsRow && value.type === "ivr",
  });
  const timeConditions = useQuery({
    queryKey: ["time-conditions"],
    queryFn: endpoints.timeConditions,
    enabled: needsRow && value.type === "time_condition",
  });

  let rowOptions: { value: string; label: string }[] = [];
  let loading = false;
  switch (value.type) {
    case "extension":
      loading = extensions.isLoading;
      rowOptions = (extensions.data ?? []).map((e) => ({
        value: e.id,
        label: `${e.number} — ${e.displayName}`,
      }));
      break;
    case "ring_group":
      loading = ringGroups.isLoading;
      rowOptions = (ringGroups.data ?? []).map((g) => ({
        value: g.id,
        label: `${g.number} — ${g.name}`,
      }));
      break;
    case "ivr":
      loading = ivrMenus.isLoading;
      rowOptions = (ivrMenus.data ?? []).map((m) => ({
        value: m.id,
        label: `${m.number} — ${m.name}`,
      }));
      break;
    case "time_condition":
      loading = timeConditions.isLoading;
      rowOptions = (timeConditions.data ?? []).map((t) => ({ value: t.id, label: t.name }));
      break;
    default:
      break;
  }

  const typeData = allowNone
    ? [{ value: "", label: "— none —" }, ...TYPE_OPTIONS]
    : TYPE_OPTIONS;

  return (
    <Stack gap="xs">
      <Group grow align="flex-start">
        <Select
          label={label}
          description={description}
          data={typeData}
          value={value.type ?? ""}
          // Clearing the id alongside the type is what keeps the pair consistent. Leaving a
          // stale id behind is the shape the server rejects, and the one a user cannot see.
          onChange={(next) =>
            onChange({ type: (next || null) as DestinationType | null, id: null })
          }
          allowDeselect={false}
        />

        {needsRow && (
          <Select
            label="Destination"
            placeholder={loading ? "Loading…" : "Select"}
            data={rowOptions}
            value={value.id ?? ""}
            onChange={(next) => onChange({ ...value, id: next || null })}
            searchable
            nothingFoundMessage="None configured yet"
            disabled={loading}
          />
        )}

        {/* A literal number rather than a row reference, so free text - not a picker. */}
        {value.type === "external" && (
          <TextInput
            label="Number"
            description="Dialled back out through Kamailio"
            placeholder="14165551234"
            value={value.id ?? ""}
            onChange={(e) => onChange({ ...value, id: e.currentTarget.value || null })}
          />
        )}

        {value.type === "voicemail" && (
          <Select
            label="Mailbox"
            data={(extensions.data ?? []).map((e) => ({
              value: e.number,
              label: `${e.number} — ${e.displayName}`,
            }))}
            value={value.id ?? ""}
            onChange={(next) => onChange({ ...value, id: next || null })}
            searchable
          />
        )}
      </Group>
    </Stack>
  );
}
