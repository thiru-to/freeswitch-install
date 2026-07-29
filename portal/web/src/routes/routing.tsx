import { useState } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Alert,
  Badge,
  Button,
  Code,
  Group,
  Modal,
  NumberInput,
  Select,
  Stack,
  Switch,
  Table,
  Tabs,
  Text,
  TextInput,
} from "@mantine/core";
import { endpoints, type InboundRoute, type OutboundRoute } from "../lib/api";
import { DeleteButton, ErrorAlert, PageHeader, QueryState } from "../components/Resource";
import { DestinationPicker, type DestinationValue } from "../components/DestinationPicker";

/* ---------------------------------------------------------------------------------------
 * Inbound
 * ------------------------------------------------------------------------------------ */

function InboundModal({
  route,
  opened,
  onClose,
}: {
  route: InboundRoute | null;
  opened: boolean;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const [didPattern, setDidPattern] = useState(route?.didPattern ?? "");
  const [description, setDescription] = useState(route?.description ?? "");
  const [priority, setPriority] = useState<number | string>(route?.priority ?? 10);
  const [dest, setDest] = useState<DestinationValue>({
    type: route?.destinationType ?? null,
    id: route?.destinationId ?? null,
  });

  const save = useMutation({
    mutationFn: () => {
      const body = {
        didPattern,
        description: description || null,
        priority: Number(priority) || 10,
        destinationType: dest.type,
        destinationId: dest.id,
      };
      return route
        ? endpoints.updateInboundRoute(route.id, body)
        : endpoints.createInboundRoute(body);
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["inbound-routes"] });
      onClose();
    },
  });

  return (
    <Modal
      opened={opened}
      onClose={onClose}
      title={route ? "Edit inbound route" : "New inbound route"}
      size="lg"
    >
      <Stack>
        <ErrorAlert error={save.error} />
        <TextInput
          label="DID pattern"
          description="A regular expression matched against the dialled number"
          placeholder="^14165551234$"
          value={didPattern}
          onChange={(e) => setDidPattern(e.currentTarget.value)}
          required
        />
        <TextInput
          label="Description"
          value={description}
          onChange={(e) => setDescription(e.currentTarget.value)}
        />
        <NumberInput
          label="Priority"
          description="Lower is matched first"
          value={priority}
          onChange={setPriority}
          min={0}
        />
        <DestinationPicker label="Send calls to" value={dest} onChange={setDest} />
        <Button onClick={() => save.mutate()} loading={save.isPending} disabled={!didPattern}>
          {route ? "Save" : "Create"}
        </Button>
      </Stack>
    </Modal>
  );
}

function InboundTab() {
  const qc = useQueryClient();
  const [editing, setEditing] = useState<InboundRoute | null>(null);
  const [creating, setCreating] = useState(false);

  const { data, error, isPending, isSuccess, isPaused } = useQuery({
    queryKey: ["inbound-routes"],
    queryFn: endpoints.inboundRoutes,
  });
  const remove = useMutation({
    mutationFn: (id: string) => endpoints.deleteInboundRoute(id),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ["inbound-routes"] }),
  });

  return (
    <>
      <Group justify="flex-end" mb="sm">
        <Button size="sm" onClick={() => setCreating(true)}>
          New inbound route
        </Button>
      </Group>
      <ErrorAlert error={remove.error} />
      <QueryState
        data={data}
        error={error}
        isPending={isPending}
        isSuccess={isSuccess}
        isPaused={isPaused}
        emptyMessage="No inbound routes. Calls to your DIDs have nowhere to go."
      >
        <Table striped highlightOnHover>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Pattern</Table.Th>
              <Table.Th>Destination</Table.Th>
              <Table.Th>Priority</Table.Th>
              <Table.Th>Enabled</Table.Th>
              <Table.Th />
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {(data ?? []).map((r) => (
              <Table.Tr key={r.id}>
                <Table.Td>
                  <Code>{r.didPattern}</Code>
                  {r.description && (
                    <Text size="xs" c="dimmed">
                      {r.description}
                    </Text>
                  )}
                </Table.Td>
                <Table.Td>
                  <Badge variant="light">{r.destinationType ?? "none"}</Badge>
                </Table.Td>
                <Table.Td>{r.priority}</Table.Td>
                <Table.Td>{r.enabled ? "Yes" : "No"}</Table.Td>
                <Table.Td>
                  <Group gap={4} justify="flex-end">
                    <Button size="xs" variant="subtle" onClick={() => setEditing(r)}>
                      Edit
                    </Button>
                    <DeleteButton
                      what={`inbound route ${r.didPattern}`}
                      onConfirm={() => remove.mutate(r.id)}
                    />
                  </Group>
                </Table.Td>
              </Table.Tr>
            ))}
          </Table.Tbody>
        </Table>
      </QueryState>
      {creating && <InboundModal route={null} opened onClose={() => setCreating(false)} />}
      {editing && (
        <InboundModal key={editing.id} route={editing} opened onClose={() => setEditing(null)} />
      )}
    </>
  );
}

/* ---------------------------------------------------------------------------------------
 * Outbound
 * ------------------------------------------------------------------------------------ */

function OutboundModal({
  route,
  opened,
  onClose,
}: {
  route: OutboundRoute | null;
  opened: boolean;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const [name, setName] = useState(route?.name ?? "");
  const [pattern, setPattern] = useState(route?.pattern ?? "");
  const [trunkId, setTrunkId] = useState(route?.trunkId ?? "");
  const [priority, setPriority] = useState<number | string>(route?.priority ?? 10);
  const [stripDigits, setStripDigits] = useState<number | string>(route?.stripDigits ?? 0);
  const [prependDigits, setPrependDigits] = useState(route?.prependDigits ?? "");
  const [isEmergency, setIsEmergency] = useState(route?.isEmergency ?? false);

  const trunks = useQuery({ queryKey: ["trunks"], queryFn: endpoints.trunks });

  const save = useMutation({
    mutationFn: () => {
      const body = {
        name,
        pattern,
        trunkId: trunkId || null,
        priority: Number(priority) || 10,
        stripDigits: Number(stripDigits) || 0,
        prependDigits: prependDigits || null,
        isEmergency,
      };
      return route
        ? endpoints.updateOutboundRoute(route.id, body)
        : endpoints.createOutboundRoute(body);
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["outbound-routes"] });
      onClose();
    },
  });

  return (
    <Modal
      opened={opened}
      onClose={onClose}
      title={route ? "Edit outbound route" : "New outbound route"}
      size="lg"
    >
      <Stack>
        <ErrorAlert error={save.error} />
        <TextInput
          label="Name"
          value={name}
          onChange={(e) => setName(e.currentTarget.value)}
          required
        />
        <TextInput
          label="Pattern"
          description="A regular expression. The API rejects one that will not compile — better than discovering it when a call fails."
          placeholder="^1[0-9]{10}$"
          value={pattern}
          onChange={(e) => setPattern(e.currentTarget.value)}
          required
        />
        <Select
          label="Trunk"
          data={(trunks.data ?? []).map((t) => ({ value: t.id, label: t.name }))}
          value={trunkId}
          onChange={(v) => setTrunkId(v ?? "")}
          searchable
        />
        <Group grow>
          <NumberInput
            label="Strip digits"
            description="From the front"
            value={stripDigits}
            onChange={setStripDigits}
            min={0}
          />
          <TextInput
            label="Prepend"
            value={prependDigits}
            onChange={(e) => setPrependDigits(e.currentTarget.value)}
          />
          <NumberInput label="Priority" value={priority} onChange={setPriority} min={0} />
        </Group>
        <Switch
          label="Emergency route"
          checked={isEmergency}
          onChange={(e) => setIsEmergency(e.currentTarget.checked)}
        />
        {isEmergency && (
          <Alert color="orange" title="Emergency routes bypass everything">
            Matched before fraud limits, time conditions and route permissions, by design. It
            must have a trunk — a 911 call blocked by your own toll-fraud cap is the worst
            failure this system can have.
          </Alert>
        )}
        <Button
          onClick={() => save.mutate()}
          loading={save.isPending}
          disabled={!name || !pattern}
        >
          {route ? "Save" : "Create"}
        </Button>
      </Stack>
    </Modal>
  );
}

function OutboundTab() {
  const qc = useQueryClient();
  const [editing, setEditing] = useState<OutboundRoute | null>(null);
  const [creating, setCreating] = useState(false);

  const { data, error, isPending, isSuccess, isPaused } = useQuery({
    queryKey: ["outbound-routes"],
    queryFn: endpoints.outboundRoutes,
  });
  const trunks = useQuery({ queryKey: ["trunks"], queryFn: endpoints.trunks });
  const remove = useMutation({
    mutationFn: (id: string) => endpoints.deleteOutboundRoute(id),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ["outbound-routes"] }),
  });

  const trunkName = (id: string | null) =>
    id ? ((trunks.data ?? []).find((t) => t.id === id)?.name ?? "unknown") : "—";

  return (
    <>
      <Group justify="flex-end" mb="sm">
        <Button size="sm" onClick={() => setCreating(true)}>
          New outbound route
        </Button>
      </Group>
      <ErrorAlert error={remove.error} />
      <QueryState
        data={data}
        error={error}
        isPending={isPending}
        isSuccess={isSuccess}
        isPaused={isPaused}
        emptyMessage="No outbound routes. Nobody can dial out."
      >
        <Table striped highlightOnHover>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Name</Table.Th>
              <Table.Th>Pattern</Table.Th>
              <Table.Th>Trunk</Table.Th>
              <Table.Th>Manipulation</Table.Th>
              <Table.Th>Priority</Table.Th>
              <Table.Th />
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {(data ?? [])
              .slice()
              // Emergency first, then by priority — the order the dialplan evaluates them in,
              // so the table reads the way the system behaves.
              .sort((a, b) =>
                a.isEmergency === b.isEmergency
                  ? a.priority - b.priority
                  : a.isEmergency
                    ? -1
                    : 1,
              )
              .map((r) => (
                <Table.Tr key={r.id}>
                  <Table.Td>
                    <Group gap={6}>
                      <Text fw={500}>{r.name}</Text>
                      {r.isEmergency && (
                        <Badge color="orange" variant="light" size="sm">
                          emergency
                        </Badge>
                      )}
                    </Group>
                  </Table.Td>
                  <Table.Td>
                    <Code>{r.pattern}</Code>
                  </Table.Td>
                  <Table.Td>{trunkName(r.trunkId)}</Table.Td>
                  <Table.Td>
                    <Text size="xs" c="dimmed">
                      {r.stripDigits ? `strip ${r.stripDigits}` : ""}
                      {r.stripDigits && r.prependDigits ? ", " : ""}
                      {r.prependDigits ? `prepend ${r.prependDigits}` : ""}
                      {!r.stripDigits && !r.prependDigits ? "none" : ""}
                    </Text>
                  </Table.Td>
                  <Table.Td>{r.priority}</Table.Td>
                  <Table.Td>
                    <Group gap={4} justify="flex-end">
                      <Button size="xs" variant="subtle" onClick={() => setEditing(r)}>
                        Edit
                      </Button>
                      <DeleteButton
                        what={`outbound route ${r.name}`}
                        onConfirm={() => remove.mutate(r.id)}
                      />
                    </Group>
                  </Table.Td>
                </Table.Tr>
              ))}
          </Table.Tbody>
        </Table>
      </QueryState>
      {creating && <OutboundModal route={null} opened onClose={() => setCreating(false)} />}
      {editing && (
        <OutboundModal key={editing.id} route={editing} opened onClose={() => setEditing(null)} />
      )}
    </>
  );
}

function RoutingPage() {
  return (
    <>
      <PageHeader
        title="Routing"
        description="Where inbound calls land, and which trunk outbound calls leave through."
      />
      <Tabs defaultValue="inbound">
        <Tabs.List mb="md">
          <Tabs.Tab value="inbound">Inbound</Tabs.Tab>
          <Tabs.Tab value="outbound">Outbound</Tabs.Tab>
        </Tabs.List>
        <Tabs.Panel value="inbound">
          <InboundTab />
        </Tabs.Panel>
        <Tabs.Panel value="outbound">
          <OutboundTab />
        </Tabs.Panel>
      </Tabs>
    </>
  );
}

export const Route = createFileRoute("/routing")({ component: RoutingPage });
