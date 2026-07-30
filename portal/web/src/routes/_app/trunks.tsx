import { useState } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Badge,
  Button,
  Group,
  Modal,
  NumberInput,
  PasswordInput,
  Select,
  Stack,
  Switch,
  Table,
  Text,
  TextInput,
} from "@mantine/core";
import { endpoints, type Trunk } from "../../lib/api";
import { DeleteButton, ErrorAlert, PageHeader, QueryState } from "../../components/Resource";

function TrunkModal({
  trunk,
  opened,
  onClose,
}: {
  trunk: Trunk | null;
  opened: boolean;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const [name, setName] = useState(trunk?.name ?? "");
  const [host, setHost] = useState(trunk?.host ?? "");
  const [authMode, setAuthMode] = useState<"ip" | "register">(trunk?.authMode ?? "ip");
  const [username, setUsername] = useState(trunk?.username ?? "");
  const [password, setPassword] = useState("");
  const [port, setPort] = useState<number | string>(trunk?.port ?? 5060);
  const [priority, setPriority] = useState<number | string>(trunk?.priority ?? 10);

  const save = useMutation({
    mutationFn: async () => {
      const body = {
        name,
        host,
        authMode,
        username: username || null,
        port: Number(port) || 5060,
        priority: Number(priority) || 10,
      };
      const saved = trunk
        ? await endpoints.updateTrunk(trunk.id, body)
        : await endpoints.createTrunk(body);
      // The credential goes through its own endpoint so it never lands in a patch body or an
      // audit diff. Only sent when actually entered - an empty box means "leave it alone",
      // not "clear it", which is what an operator editing the port would expect.
      if (password) await endpoints.setTrunkPassword(saved.id, password);
      return saved;
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["trunks"] });
      onClose();
    },
  });

  return (
    <Modal opened={opened} onClose={onClose} title={trunk ? `Edit ${trunk.name}` : "New trunk"}>
      <Stack>
        <ErrorAlert error={save.error} />
        <TextInput
          label="Name"
          description="Also the FreeSWITCH gateway name, which is how CDRs attribute a call to this carrier"
          value={name}
          onChange={(e) => setName(e.currentTarget.value)}
          required
        />
        <TextInput
          label="Host"
          placeholder="sip.carrier.example"
          value={host}
          onChange={(e) => setHost(e.currentTarget.value)}
          required
        />
        <Group grow>
          <NumberInput label="Port" value={port} onChange={setPort} min={1} max={65535} />
          <NumberInput
            label="Priority"
            description="Lower wins"
            value={priority}
            onChange={setPriority}
            min={0}
          />
        </Group>
        <Select
          label="Authentication"
          data={[
            { value: "ip", label: "IP address" },
            { value: "register", label: "Register with credentials" },
          ]}
          value={authMode}
          onChange={(v) => setAuthMode((v as "ip" | "register") ?? "ip")}
          allowDeselect={false}
        />
        {authMode === "register" && (
          <>
            <TextInput
              label="Username"
              value={username}
              onChange={(e) => setUsername(e.currentTarget.value)}
              required
            />
            <PasswordInput
              label="Password"
              description={trunk ? "Leave blank to keep the current one" : undefined}
              value={password}
              onChange={(e) => setPassword(e.currentTarget.value)}
            />
          </>
        )}
        {authMode === "ip" && (
          <Text size="xs" c="dimmed">
            The carrier's address is written into Kamailio's permissions table, which is also
            what stops the responsive firewall rate-limiting them.
          </Text>
        )}
        <Button onClick={() => save.mutate()} loading={save.isPending} disabled={!name || !host}>
          {trunk ? "Save" : "Create"}
        </Button>
      </Stack>
    </Modal>
  );
}

function TrunksPage() {
  const qc = useQueryClient();
  const [editing, setEditing] = useState<Trunk | null>(null);
  const [creating, setCreating] = useState(false);

  const { data, error, isPending, isSuccess, isPaused } = useQuery({
    queryKey: ["trunks"],
    queryFn: endpoints.trunks,
  });

  const remove = useMutation({
    mutationFn: (id: string) => endpoints.deleteTrunk(id),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ["trunks"] }),
  });
  const toggle = useMutation({
    mutationFn: ({ id, enabled }: { id: string; enabled: boolean }) =>
      endpoints.updateTrunk(id, { enabled }),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ["trunks"] }),
  });

  return (
    <>
      <PageHeader
        title="Trunks"
        description="Carrier connections. Kamailio reaches these, not FreeSWITCH — the media core never talks to a carrier directly."
        action={<Button onClick={() => setCreating(true)}>New trunk</Button>}
      />

      <ErrorAlert error={remove.error ?? toggle.error} />

      <QueryState
        data={data}
        error={error}
        isPending={isPending}
        isSuccess={isSuccess}
        isPaused={isPaused}
        emptyMessage="No trunks yet. Outbound calls need one."
        emptyAction={<Button onClick={() => setCreating(true)}>Add a trunk</Button>}
      >
        <Table striped highlightOnHover>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Name</Table.Th>
              <Table.Th>Host</Table.Th>
              <Table.Th>Auth</Table.Th>
              <Table.Th>Priority</Table.Th>
              <Table.Th>Enabled</Table.Th>
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
                  {t.host}
                  {t.port && t.port !== 5060 ? `:${t.port}` : ""}
                </Table.Td>
                <Table.Td>
                  <Badge variant="light" color={t.authMode === "ip" ? "blue" : "grape"}>
                    {t.authMode === "ip" ? "IP" : `register${t.username ? ` (${t.username})` : ""}`}
                  </Badge>
                </Table.Td>
                <Table.Td>{t.priority}</Table.Td>
                <Table.Td>
                  <Switch
                    checked={t.enabled}
                    onChange={(e) => toggle.mutate({ id: t.id, enabled: e.currentTarget.checked })}
                  />
                </Table.Td>
                <Table.Td>
                  <Group gap={4} justify="flex-end">
                    <Button size="xs" variant="subtle" onClick={() => setEditing(t)}>
                      Edit
                    </Button>
                    <DeleteButton
                      what={`trunk ${t.name}`}
                      onConfirm={() => remove.mutate(t.id)}
                      loading={remove.isPending}
                    />
                  </Group>
                </Table.Td>
              </Table.Tr>
            ))}
          </Table.Tbody>
        </Table>
      </QueryState>

      {creating && <TrunkModal trunk={null} opened onClose={() => setCreating(false)} />}
      {editing && (
        // Keyed so the form state resets when a different trunk is picked - without it the
        // fields keep the previous row's values.
        <TrunkModal key={editing.id} trunk={editing} opened onClose={() => setEditing(null)} />
      )}
    </>
  );
}

export const Route = createFileRoute("/_app/trunks")({ component: TrunksPage });
