import { useState } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  ActionIcon,
  Badge,
  Button,
  Checkbox,
  Group,
  Modal,
  NumberInput,
  Select,
  Stack,
  Table,
  Tabs,
  Text,
  TextInput,
} from "@mantine/core";
import {
  endpoints,
  type IvrMenu,
  type RingGroup,
  type TimeCondition,
  type TimeConditionRule,
} from "../../lib/api";
import { DeleteButton, ErrorAlert, PageHeader, QueryState } from "../../components/Resource";
import { DestinationPicker, type DestinationValue } from "../../components/DestinationPicker";

/* ---------------------------------------------------------------------------------------
 * Ring groups
 * ------------------------------------------------------------------------------------ */

function RingGroupModal({
  group,
  opened,
  onClose,
}: {
  group: RingGroup | null;
  opened: boolean;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const [number, setNumber] = useState(group?.number ?? "");
  const [name, setName] = useState(group?.name ?? "");
  const [strategy, setStrategy] = useState(group?.strategy ?? "simultaneous");
  const [timeout, setTimeout] = useState<number | string>(group?.ringTimeoutSec ?? 30);
  const [failover, setFailover] = useState<DestinationValue>({
    type: group?.failoverType ?? null,
    id: group?.failoverId ?? null,
  });

  const save = useMutation({
    mutationFn: () => {
      const body = {
        number,
        name,
        strategy: strategy as "simultaneous" | "sequential",
        ringTimeoutSec: Number(timeout) || 30,
        failoverType: failover.type,
        failoverId: failover.id,
      };
      return group ? endpoints.updateRingGroup(group.id, body) : endpoints.createRingGroup(body);
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["ring-groups"] });
      onClose();
    },
  });

  return (
    <Modal opened={opened} onClose={onClose} title={group ? `Edit ${group.name}` : "New ring group"} size="lg">
      <Stack>
        <ErrorAlert error={save.error} />
        <Group grow>
          <TextInput
            label="Number"
            description="Dial this from any phone in the tenant"
            placeholder="600"
            value={number}
            onChange={(e) => setNumber(e.currentTarget.value)}
            required
          />
          <TextInput
            label="Name"
            placeholder="Sales"
            value={name}
            onChange={(e) => setName(e.currentTarget.value)}
            required
          />
        </Group>
        <Group grow>
          <Select
            label="Strategy"
            data={[
              { value: "simultaneous", label: "Ring everyone at once" },
              { value: "sequential", label: "Ring one at a time" },
            ]}
            value={strategy}
            onChange={(v) => setStrategy((v as "simultaneous" | "sequential") ?? "simultaneous")}
            allowDeselect={false}
          />
          <NumberInput label="Ring for (seconds)" value={timeout} onChange={setTimeout} min={5} />
        </Group>
        <DestinationPicker
          label="If nobody answers"
          description="Falls back to the group's own voicemail when left empty"
          value={failover}
          onChange={setFailover}
        />
        <Button
          onClick={() => save.mutate()}
          loading={save.isPending}
          disabled={!number || !name}
        >
          {group ? "Save" : "Create"}
        </Button>
      </Stack>
    </Modal>
  );
}

function MembersModal({ group, onClose }: { group: RingGroup; onClose: () => void }) {
  const qc = useQueryClient();
  const [extensionId, setExtensionId] = useState("");
  const [delaySec, setDelaySec] = useState<number | string>(0);

  const members = useQuery({
    queryKey: ["ring-group-members", group.id],
    queryFn: () => endpoints.ringGroupMembers(group.id),
  });
  const extensions = useQuery({ queryKey: ["extensions"], queryFn: endpoints.extensions });

  const invalidate = () => {
    void qc.invalidateQueries({ queryKey: ["ring-group-members", group.id] });
  };
  const add = useMutation({
    mutationFn: () =>
      endpoints.addRingGroupMember(group.id, { extensionId, delaySec: Number(delaySec) || 0 }),
    onSuccess: () => {
      setExtensionId("");
      setDelaySec(0);
      invalidate();
    },
  });
  const remove = useMutation({
    mutationFn: (memberId: string) => endpoints.removeRingGroupMember(group.id, memberId),
    onSuccess: invalidate,
  });

  const inGroup = new Set((members.data ?? []).map((m) => m.extensionId));
  const available = (extensions.data ?? []).filter((e) => !inGroup.has(e.id));

  return (
    <Modal opened onClose={onClose} title={`Members of ${group.name}`} size="lg">
      <Stack>
        <ErrorAlert error={add.error ?? remove.error} />
        <Table>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Extension</Table.Th>
              <Table.Th>Delay</Table.Th>
              <Table.Th />
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {(members.data ?? []).map((m) => (
              <Table.Tr key={m.id}>
                <Table.Td>
                  {m.number} — {m.displayName}
                </Table.Td>
                <Table.Td>{m.delaySec ? `${m.delaySec}s` : "—"}</Table.Td>
                <Table.Td>
                  <Group justify="flex-end">
                    <ActionIcon
                      variant="subtle"
                      color="red"
                      onClick={() => remove.mutate(m.id)}
                      aria-label="Remove"
                    >
                      ×
                    </ActionIcon>
                  </Group>
                </Table.Td>
              </Table.Tr>
            ))}
            {(members.data ?? []).length === 0 && (
              <Table.Tr>
                <Table.Td colSpan={3}>
                  <Text c="dimmed" size="sm">
                    Empty. Calls go straight to the failover.
                  </Text>
                </Table.Td>
              </Table.Tr>
            )}
          </Table.Tbody>
        </Table>

        <Group align="flex-end">
          <Select
            label="Add extension"
            data={available.map((e) => ({ value: e.id, label: `${e.number} — ${e.displayName}` }))}
            value={extensionId}
            onChange={(v) => setExtensionId(v ?? "")}
            searchable
            nothingFoundMessage="Everyone is already a member"
            style={{ flex: 1 }}
          />
          {/* Only meaningful on a simultaneous group - a sequential group already rings in
              order, and the Lua ignores the delay there. */}
          {group.strategy === "simultaneous" && (
            <NumberInput
              label="Delay"
              description="Seconds"
              value={delaySec}
              onChange={setDelaySec}
              min={0}
              w={110}
            />
          )}
          <Button onClick={() => add.mutate()} disabled={!extensionId} loading={add.isPending}>
            Add
          </Button>
        </Group>
      </Stack>
    </Modal>
  );
}

function RingGroupsTab() {
  const qc = useQueryClient();
  const [editing, setEditing] = useState<RingGroup | null>(null);
  const [members, setMembers] = useState<RingGroup | null>(null);
  const [creating, setCreating] = useState(false);

  const { data, error, isPending, isSuccess, isPaused } = useQuery({
    queryKey: ["ring-groups"],
    queryFn: endpoints.ringGroups,
  });
  const remove = useMutation({
    mutationFn: (id: string) => endpoints.deleteRingGroup(id),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ["ring-groups"] }),
  });

  return (
    <>
      <Group justify="flex-end" mb="sm">
        <Button size="sm" onClick={() => setCreating(true)}>
          New ring group
        </Button>
      </Group>
      <ErrorAlert error={remove.error} />
      <QueryState
        data={data}
        error={error}
        isPending={isPending}
        isSuccess={isSuccess}
        isPaused={isPaused}
        emptyMessage="No ring groups yet."
      >
        <Table striped highlightOnHover>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Number</Table.Th>
              <Table.Th>Name</Table.Th>
              <Table.Th>Strategy</Table.Th>
              <Table.Th>Ring</Table.Th>
              <Table.Th>Failover</Table.Th>
              <Table.Th />
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {(data ?? []).map((g) => (
              <Table.Tr key={g.id}>
                <Table.Td>{g.number}</Table.Td>
                <Table.Td>
                  <Text fw={500}>{g.name}</Text>
                </Table.Td>
                <Table.Td>
                  <Badge variant="light">{g.strategy}</Badge>
                </Table.Td>
                <Table.Td>{g.ringTimeoutSec}s</Table.Td>
                <Table.Td>
                  <Text size="sm" c="dimmed">
                    {g.failoverType ?? "voicemail"}
                  </Text>
                </Table.Td>
                <Table.Td>
                  <Group gap={4} justify="flex-end">
                    <Button size="xs" variant="subtle" onClick={() => setMembers(g)}>
                      Members
                    </Button>
                    <Button size="xs" variant="subtle" onClick={() => setEditing(g)}>
                      Edit
                    </Button>
                    <DeleteButton
                      what={`ring group ${g.name}`}
                      onConfirm={() => remove.mutate(g.id)}
                    />
                  </Group>
                </Table.Td>
              </Table.Tr>
            ))}
          </Table.Tbody>
        </Table>
      </QueryState>
      {creating && <RingGroupModal group={null} opened onClose={() => setCreating(false)} />}
      {editing && (
        <RingGroupModal key={editing.id} group={editing} opened onClose={() => setEditing(null)} />
      )}
      {members && <MembersModal key={members.id} group={members} onClose={() => setMembers(null)} />}
    </>
  );
}

/* ---------------------------------------------------------------------------------------
 * IVR menus
 * ------------------------------------------------------------------------------------ */

function IvrModal({
  menu,
  opened,
  onClose,
}: {
  menu: IvrMenu | null;
  opened: boolean;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const [number, setNumber] = useState(menu?.number ?? "");
  const [name, setName] = useState(menu?.name ?? "");
  const [greeting, setGreeting] = useState(menu?.greetingSound ?? "");
  const [timeoutSec, setTimeoutSec] = useState<number | string>(menu?.timeoutSec ?? 5);
  const [maxRetries, setMaxRetries] = useState<number | string>(menu?.maxRetries ?? 3);
  const [onTimeout, setOnTimeout] = useState<DestinationValue>({
    type: menu?.timeoutType ?? null,
    id: menu?.timeoutId ?? null,
  });

  const save = useMutation({
    mutationFn: () => {
      const body = {
        number,
        name,
        greetingSound: greeting || null,
        timeoutSec: Number(timeoutSec) || 5,
        maxRetries: Number(maxRetries) || 3,
        timeoutType: onTimeout.type,
        timeoutId: onTimeout.id,
      };
      return menu ? endpoints.updateIvrMenu(menu.id, body) : endpoints.createIvrMenu(body);
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["ivr-menus"] });
      onClose();
    },
  });

  return (
    <Modal opened={opened} onClose={onClose} title={menu ? `Edit ${menu.name}` : "New IVR menu"} size="lg">
      <Stack>
        <ErrorAlert error={save.error} />
        <Group grow>
          <TextInput
            label="Number"
            placeholder="700"
            value={number}
            onChange={(e) => setNumber(e.currentTarget.value)}
            required
          />
          <TextInput
            label="Name"
            placeholder="Main menu"
            value={name}
            onChange={(e) => setName(e.currentTarget.value)}
            required
          />
        </Group>
        <TextInput
          label="Greeting"
          description="A sound file path FreeSWITCH can play"
          placeholder="/usr/local/freeswitch/sounds/custom/greeting.wav"
          value={greeting}
          onChange={(e) => setGreeting(e.currentTarget.value)}
        />
        <Group grow>
          <NumberInput
            label="Wait for a digit (seconds)"
            value={timeoutSec}
            onChange={setTimeoutSec}
            min={1}
          />
          <NumberInput label="Attempts" value={maxRetries} onChange={setMaxRetries} min={1} />
        </Group>
        <DestinationPicker
          label="If they press nothing"
          description="The most common path in practice — rotary phones, handsets put down, speech that never registers"
          value={onTimeout}
          onChange={setOnTimeout}
        />
        <Button onClick={() => save.mutate()} loading={save.isPending} disabled={!number || !name}>
          {menu ? "Save" : "Create"}
        </Button>
      </Stack>
    </Modal>
  );
}

function IvrOptionsModal({ menu, onClose }: { menu: IvrMenu; onClose: () => void }) {
  const qc = useQueryClient();
  const [digit, setDigit] = useState("1");
  const [dest, setDest] = useState<DestinationValue>({ type: null, id: null });

  const options = useQuery({
    queryKey: ["ivr-options", menu.id],
    queryFn: () => endpoints.ivrOptions(menu.id),
  });
  const invalidate = () => void qc.invalidateQueries({ queryKey: ["ivr-options", menu.id] });

  const setOption = useMutation({
    mutationFn: () =>
      endpoints.setIvrOption(menu.id, digit, {
        destinationType: dest.type!,
        destinationId: dest.id,
      }),
    onSuccess: () => {
      setDest({ type: null, id: null });
      invalidate();
    },
  });
  const removeOption = useMutation({
    mutationFn: (d: string) => endpoints.deleteIvrOption(menu.id, d),
    onSuccess: invalidate,
  });

  const DIGITS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "#"];

  return (
    <Modal opened onClose={onClose} title={`Options for ${menu.name}`} size="lg">
      <Stack>
        <ErrorAlert error={setOption.error ?? removeOption.error} />
        <Table>
          <Table.Thead>
            <Table.Tr>
              <Table.Th w={80}>Digit</Table.Th>
              <Table.Th>Goes to</Table.Th>
              <Table.Th />
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {(options.data ?? []).map((o) => (
              <Table.Tr key={o.id}>
                <Table.Td>
                  <Badge size="lg" variant="light">
                    {o.digit}
                  </Badge>
                </Table.Td>
                <Table.Td>
                  {o.destinationType}
                  {o.description ? ` — ${o.description}` : ""}
                </Table.Td>
                <Table.Td>
                  <Group justify="flex-end">
                    <ActionIcon
                      variant="subtle"
                      color="red"
                      onClick={() => removeOption.mutate(o.digit)}
                      aria-label="Remove"
                    >
                      ×
                    </ActionIcon>
                  </Group>
                </Table.Td>
              </Table.Tr>
            ))}
            {(options.data ?? []).length === 0 && (
              <Table.Tr>
                <Table.Td colSpan={3}>
                  <Text c="dimmed" size="sm">
                    No options. Every caller falls through to the timeout destination.
                  </Text>
                </Table.Td>
              </Table.Tr>
            )}
          </Table.Tbody>
        </Table>

        <Group align="flex-end">
          <Select
            label="Digit"
            data={DIGITS}
            value={digit}
            onChange={(v) => setDigit(v ?? "1")}
            w={90}
            allowDeselect={false}
          />
          <div style={{ flex: 1 }}>
            <DestinationPicker label="Goes to" value={dest} onChange={setDest} allowNone={false} />
          </div>
          <Button
            onClick={() => setOption.mutate()}
            disabled={!dest.type}
            loading={setOption.isPending}
          >
            Set
          </Button>
        </Group>
      </Stack>
    </Modal>
  );
}

function IvrTab() {
  const qc = useQueryClient();
  const [editing, setEditing] = useState<IvrMenu | null>(null);
  const [options, setOptions] = useState<IvrMenu | null>(null);
  const [creating, setCreating] = useState(false);

  const { data, error, isPending, isSuccess, isPaused } = useQuery({
    queryKey: ["ivr-menus"],
    queryFn: endpoints.ivrMenus,
  });
  const remove = useMutation({
    mutationFn: (id: string) => endpoints.deleteIvrMenu(id),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ["ivr-menus"] }),
  });

  return (
    <>
      <Group justify="flex-end" mb="sm">
        <Button size="sm" onClick={() => setCreating(true)}>
          New IVR menu
        </Button>
      </Group>
      <ErrorAlert error={remove.error} />
      <QueryState
        data={data}
        error={error}
        isPending={isPending}
        isSuccess={isSuccess}
        isPaused={isPaused}
        emptyMessage="No IVR menus yet."
      >
        <Table striped highlightOnHover>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Number</Table.Th>
              <Table.Th>Name</Table.Th>
              <Table.Th>Wait</Table.Th>
              <Table.Th>Attempts</Table.Th>
              <Table.Th>On timeout</Table.Th>
              <Table.Th />
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {(data ?? []).map((m) => (
              <Table.Tr key={m.id}>
                <Table.Td>{m.number}</Table.Td>
                <Table.Td>
                  <Text fw={500}>{m.name}</Text>
                </Table.Td>
                <Table.Td>{m.timeoutSec}s</Table.Td>
                <Table.Td>{m.maxRetries}</Table.Td>
                <Table.Td>
                  <Text size="sm" c="dimmed">
                    {m.timeoutType ?? "hang up"}
                  </Text>
                </Table.Td>
                <Table.Td>
                  <Group gap={4} justify="flex-end">
                    <Button size="xs" variant="subtle" onClick={() => setOptions(m)}>
                      Options
                    </Button>
                    <Button size="xs" variant="subtle" onClick={() => setEditing(m)}>
                      Edit
                    </Button>
                    <DeleteButton what={`IVR ${m.name}`} onConfirm={() => remove.mutate(m.id)} />
                  </Group>
                </Table.Td>
              </Table.Tr>
            ))}
          </Table.Tbody>
        </Table>
      </QueryState>
      {creating && <IvrModal menu={null} opened onClose={() => setCreating(false)} />}
      {editing && <IvrModal key={editing.id} menu={editing} opened onClose={() => setEditing(null)} />}
      {options && (
        <IvrOptionsModal key={options.id} menu={options} onClose={() => setOptions(null)} />
      )}
    </>
  );
}

/* ---------------------------------------------------------------------------------------
 * Time conditions
 * ------------------------------------------------------------------------------------ */

const WEEKDAYS = [
  { value: 0, label: "Sun" },
  { value: 1, label: "Mon" },
  { value: 2, label: "Tue" },
  { value: 3, label: "Wed" },
  { value: 4, label: "Thu" },
  { value: 5, label: "Fri" },
  { value: 6, label: "Sat" },
];

function RuleEditor({
  rule,
  onChange,
  onRemove,
}: {
  rule: TimeConditionRule;
  onChange: (r: TimeConditionRule) => void;
  onRemove: () => void;
}) {
  const days = rule.days ?? [];
  const toggleDay = (d: number) => {
    const next = days.includes(d) ? days.filter((x) => x !== d) : [...days, d].sort();
    onChange({ ...rule, days: next.length ? next : undefined });
  };

  return (
    <Stack gap="xs" p="sm" style={{ border: "1px solid var(--mantine-color-default-border)", borderRadius: 6 }}>
      <Group justify="space-between">
        <Checkbox
          label="Exclusion (a holiday)"
          checked={rule.invert ?? false}
          onChange={(e) => onChange({ ...rule, invert: e.currentTarget.checked || undefined })}
        />
        <ActionIcon variant="subtle" color="red" onClick={onRemove} aria-label="Remove rule">
          ×
        </ActionIcon>
      </Group>
      {rule.invert && (
        <Text size="xs" c="dimmed">
          An exclusion that matches wins over every other rule, wherever it sits in the list.
          That is what makes Christmas Day beat "Mon–Fri 09:00–17:00".
        </Text>
      )}
      <Group gap={4}>
        {WEEKDAYS.map((d) => (
          <Button
            key={d.value}
            size="compact-xs"
            variant={days.includes(d.value) ? "filled" : "default"}
            onClick={() => toggleDay(d.value)}
          >
            {d.label}
          </Button>
        ))}
      </Group>
      <Group grow>
        <TextInput
          label="From"
          placeholder="09:00"
          value={rule.start ?? ""}
          onChange={(e) => onChange({ ...rule, start: e.currentTarget.value || undefined })}
        />
        <TextInput
          label="To"
          placeholder="17:00"
          value={rule.end ?? ""}
          onChange={(e) => onChange({ ...rule, end: e.currentTarget.value || undefined })}
        />
        <TextInput
          label="Specific date"
          placeholder="2026-12-25"
          value={rule.date ?? ""}
          onChange={(e) => onChange({ ...rule, date: e.currentTarget.value || undefined })}
        />
      </Group>
    </Stack>
  );
}

function TimeConditionModal({
  condition,
  opened,
  onClose,
}: {
  condition: TimeCondition | null;
  opened: boolean;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const tenant = useQuery({ queryKey: ["tenant"], queryFn: endpoints.tenant });

  const [name, setName] = useState(condition?.name ?? "");
  const [timezone, setTimezone] = useState(condition?.timezone ?? "");
  const [rules, setRules] = useState<TimeConditionRule[]>(
    condition?.rules ?? [{ days: [1, 2, 3, 4, 5], start: "09:00", end: "17:00" }],
  );
  const [onMatch, setOnMatch] = useState<DestinationValue>({
    type: condition?.matchType ?? null,
    id: condition?.matchId ?? null,
  });
  const [onNoMatch, setOnNoMatch] = useState<DestinationValue>({
    type: condition?.noMatchType ?? null,
    id: condition?.noMatchId ?? null,
  });

  const save = useMutation({
    mutationFn: () => {
      const body = {
        name,
        timezone: timezone || tenant.data?.timezone || "Etc/UTC",
        rules,
        matchType: onMatch.type,
        matchId: onMatch.id,
        noMatchType: onNoMatch.type,
        noMatchId: onNoMatch.id,
      };
      return condition
        ? endpoints.updateTimeCondition(condition.id, body)
        : endpoints.createTimeCondition(body);
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["time-conditions"] });
      onClose();
    },
  });

  return (
    <Modal
      opened={opened}
      onClose={onClose}
      title={condition ? `Edit ${condition.name}` : "New time condition"}
      size="lg"
    >
      <Stack>
        <ErrorAlert error={save.error} />
        <Group grow>
          <TextInput
            label="Name"
            placeholder="Business hours"
            value={name}
            onChange={(e) => setName(e.currentTarget.value)}
            required
          />
          <TextInput
            label="Timezone"
            description="Evaluated here, not on the server clock"
            placeholder={tenant.data?.timezone ?? "America/Toronto"}
            value={timezone}
            onChange={(e) => setTimezone(e.currentTarget.value)}
          />
        </Group>

        <Text size="sm" fw={500}>
          Rules
        </Text>
        {rules.map((r, i) => (
          <RuleEditor
            key={i}
            rule={r}
            onChange={(next) => setRules(rules.map((x, j) => (j === i ? next : x)))}
            onRemove={() => setRules(rules.filter((_, j) => j !== i))}
          />
        ))}
        <Button variant="default" size="xs" onClick={() => setRules([...rules, {}])}>
          Add rule
        </Button>

        <DestinationPicker label="Inside these hours" value={onMatch} onChange={setOnMatch} />
        <DestinationPicker label="Outside them" value={onNoMatch} onChange={setOnNoMatch} />

        <Button onClick={() => save.mutate()} loading={save.isPending} disabled={!name}>
          {condition ? "Save" : "Create"}
        </Button>
      </Stack>
    </Modal>
  );
}

function describeRule(r: TimeConditionRule): string {
  const parts: string[] = [];
  if (r.date) parts.push(r.date);
  if (r.days?.length) {
    parts.push(r.days.map((d) => WEEKDAYS.find((w) => w.value === d)?.label ?? d).join(" "));
  }
  if (r.start || r.end) parts.push(`${r.start ?? "00:00"}–${r.end ?? "24:00"}`);
  const body = parts.join(" ") || "always";
  return r.invert ? `except ${body}` : body;
}

function TimeConditionsTab() {
  const qc = useQueryClient();
  const [editing, setEditing] = useState<TimeCondition | null>(null);
  const [creating, setCreating] = useState(false);

  const { data, error, isPending, isSuccess, isPaused } = useQuery({
    queryKey: ["time-conditions"],
    queryFn: endpoints.timeConditions,
  });
  const remove = useMutation({
    mutationFn: (id: string) => endpoints.deleteTimeCondition(id),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ["time-conditions"] }),
  });

  return (
    <>
      <Group justify="flex-end" mb="sm">
        <Button size="sm" onClick={() => setCreating(true)}>
          New time condition
        </Button>
      </Group>
      <ErrorAlert error={remove.error} />
      <QueryState
        data={data}
        error={error}
        isPending={isPending}
        isSuccess={isSuccess}
        isPaused={isPaused}
        emptyMessage="No time conditions. Every call is treated as in-hours."
      >
        <Table striped highlightOnHover>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Name</Table.Th>
              <Table.Th>Timezone</Table.Th>
              <Table.Th>Rules</Table.Th>
              <Table.Th>In / out</Table.Th>
              <Table.Th />
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {(data ?? []).map((t) => (
              <Table.Tr key={t.id}>
                <Table.Td>
                  <Text fw={500}>{t.name}</Text>
                </Table.Td>
                <Table.Td>
                  <Text size="sm">{t.timezone}</Text>
                </Table.Td>
                <Table.Td>
                  <Stack gap={2}>
                    {(t.rules ?? []).map((r, i) => (
                      <Text key={i} size="xs" c={r.invert ? "orange" : undefined}>
                        {describeRule(r)}
                      </Text>
                    ))}
                  </Stack>
                </Table.Td>
                <Table.Td>
                  <Text size="xs" c="dimmed">
                    {t.matchType ?? "—"} / {t.noMatchType ?? "—"}
                  </Text>
                </Table.Td>
                <Table.Td>
                  <Group gap={4} justify="flex-end">
                    <Button size="xs" variant="subtle" onClick={() => setEditing(t)}>
                      Edit
                    </Button>
                    <DeleteButton
                      what={`time condition ${t.name}`}
                      onConfirm={() => remove.mutate(t.id)}
                    />
                  </Group>
                </Table.Td>
              </Table.Tr>
            ))}
          </Table.Tbody>
        </Table>
      </QueryState>
      {creating && <TimeConditionModal condition={null} opened onClose={() => setCreating(false)} />}
      {editing && (
        <TimeConditionModal
          key={editing.id}
          condition={editing}
          opened
          onClose={() => setEditing(null)}
        />
      )}
    </>
  );
}

function CallFlowsPage() {
  return (
    <>
      <PageHeader
        title="Call flows"
        description="Ring groups, auto-attendants and business hours. These chain into each other — an IVR option can point at a time condition, which points at a ring group."
      />
      <Tabs defaultValue="ring-groups">
        <Tabs.List mb="md">
          <Tabs.Tab value="ring-groups">Ring groups</Tabs.Tab>
          <Tabs.Tab value="ivr">IVR menus</Tabs.Tab>
          <Tabs.Tab value="time-conditions">Time conditions</Tabs.Tab>
        </Tabs.List>
        <Tabs.Panel value="ring-groups">
          <RingGroupsTab />
        </Tabs.Panel>
        <Tabs.Panel value="ivr">
          <IvrTab />
        </Tabs.Panel>
        <Tabs.Panel value="time-conditions">
          <TimeConditionsTab />
        </Tabs.Panel>
      </Tabs>
    </>
  );
}

export const Route = createFileRoute("/_app/call-flows")({ component: CallFlowsPage });
