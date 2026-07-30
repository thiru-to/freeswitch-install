import { useState } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Alert,
  Badge,
  Button,
  Code,
  Group,
  Loader,
  Modal,
  Stack,
  Switch,
  Table,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import { endpoints, type Extension } from "../../lib/api";
import { CallHandlingModal } from "../../components/CallHandlingModal";

function CreateExtensionModal({
  opened,
  onClose,
}: {
  opened: boolean;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const [number, setNumber] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [voicemail, setVoicemail] = useState(true);
  const [created, setCreated] = useState<Extension | null>(null);

  const mutation = useMutation({
    mutationFn: () =>
      endpoints.createExtension({ number, displayName, voicemailEnabled: voicemail }),
    onSuccess: (ext) => {
      setCreated(ext);
      void qc.invalidateQueries({ queryKey: ["extensions"] });
    },
  });

  function reset() {
    setNumber("");
    setDisplayName("");
    setVoicemail(true);
    setCreated(null);
    mutation.reset();
    onClose();
  }

  /**
   * The SIP password is shown exactly once. It is stored encrypted and projected into Kamailio
   * only as an HA1 digest, so it genuinely cannot be recovered afterwards — saying so plainly
   * is better than letting someone close the dialog and find out later.
   */
  if (created) {
    return (
      <Modal opened={opened} onClose={reset} title={`Extension ${created.number} created`}>
        <Stack>
          <Alert color="yellow" title="Save these now">
            Both are stored encrypted and cannot be shown again. The PIN can be reset later; the
            SIP password cannot be recovered, only replaced.
          </Alert>
          <div>
            <Text size="sm" fw={500}>
              SIP password — for the handset
            </Text>
            <Code block>{created.sipPassword}</Code>
          </div>
          <div>
            <Text size="sm" fw={500}>
              Voicemail PIN — for the user
            </Text>
            <Code block>{created.voicemailPin}</Code>
            <Text size="xs" c="dimmed" mt={4}>
              Dial *97 from the extension to listen, *98 from any other phone.
            </Text>
          </div>
          <Button onClick={reset}>Done</Button>
        </Stack>
      </Modal>
    );
  }

  return (
    <Modal opened={opened} onClose={reset} title="New extension">
      <Stack>
        <TextInput
          label="Number"
          placeholder="1001"
          value={number}
          onChange={(e) => setNumber(e.currentTarget.value)}
          required
        />
        <TextInput
          label="Display name"
          placeholder="Reception"
          value={displayName}
          onChange={(e) => setDisplayName(e.currentTarget.value)}
          required
        />
        <Switch
          label="Voicemail"
          checked={voicemail}
          onChange={(e) => setVoicemail(e.currentTarget.checked)}
        />
        {mutation.error ? (
          <Alert color="red">{(mutation.error as Error).message}</Alert>
        ) : null}
        <Group justify="flex-end">
          <Button variant="subtle" onClick={reset}>
            Cancel
          </Button>
          <Button
            onClick={() => mutation.mutate()}
            loading={mutation.isPending}
            disabled={!number || !displayName}
          >
            Create
          </Button>
        </Group>
      </Stack>
    </Modal>
  );
}

function Extensions() {
  const qc = useQueryClient();
  const [modalOpen, setModalOpen] = useState(false);
  const [callHandling, setCallHandling] = useState<Extension | null>(null);

  const { data, isLoading, error } = useQuery<Extension[]>({
    queryKey: ["extensions"],
    queryFn: () => endpoints.extensions(),
  });

  const toggle = useMutation({
    mutationFn: ({ id, enabled }: { id: string; enabled: boolean }) =>
      endpoints.updateExtension(id, { enabled }),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ["extensions"] }),
  });

  if (isLoading) {
    return (
      <Group justify="center" p="xl">
        <Loader />
      </Group>
    );
  }

  if (error) {
    return (
      <Alert color="red" title="Could not load extensions">
        {(error as Error).message}
      </Alert>
    );
  }

  const rows = data ?? [];

  return (
    <Stack>
      <Group justify="space-between">
        <Title order={3}>Extensions</Title>
        <Button onClick={() => setModalOpen(true)}>New extension</Button>
      </Group>

      {rows.length === 0 ? (
        <Alert color="blue" title="No extensions yet">
          Create one to give someone a phone. It becomes registrable as soon as Kamailio has
          the credential — the portal projects it automatically.
        </Alert>
      ) : (
        <Table>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Number</Table.Th>
              <Table.Th>Name</Table.Th>
              <Table.Th>Voicemail</Table.Th>
              <Table.Th>Call handling</Table.Th>
              <Table.Th>Status</Table.Th>
              <Table.Th />
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {rows.map((ext) => (
              <Table.Tr key={ext.id}>
                <Table.Td>
                  <Text ff="monospace">{ext.number}</Text>
                </Table.Td>
                <Table.Td>{ext.displayName}</Table.Td>
                <Table.Td>
                  {ext.voicemailEnabled ? (
                    <Badge variant="light">on</Badge>
                  ) : (
                    <Text c="dimmed" size="sm">
                      off
                    </Text>
                  )}
                </Table.Td>
                <Table.Td>
                  <Group gap={4}>
                    {/* Only the states that change what happens to a call are badged. A row
                        with nothing here behaves the ordinary way, which is most of them. */}
                    {ext.dnd && (
                      <Badge color="orange" variant="light" size="sm">
                        DND
                      </Badge>
                    )}
                    {ext.forwardAllTo && (
                      <Badge color="grape" variant="light" size="sm">
                        → {ext.forwardAllTo}
                      </Badge>
                    )}
                    {!ext.callWaitingEnabled && (
                      <Badge color="gray" variant="light" size="sm">
                        no waiting
                      </Badge>
                    )}
                    <Button size="compact-xs" variant="subtle" onClick={() => setCallHandling(ext)}>
                      Edit
                    </Button>
                  </Group>
                </Table.Td>
                <Table.Td>
                  <Badge color={ext.enabled ? "green" : "gray"} variant="light">
                    {ext.enabled ? "enabled" : "disabled"}
                  </Badge>
                </Table.Td>
                <Table.Td>
                  <Switch
                    checked={ext.enabled}
                    onChange={(e) =>
                      toggle.mutate({ id: ext.id, enabled: e.currentTarget.checked })
                    }
                    aria-label={`Toggle extension ${ext.number}`}
                  />
                </Table.Td>
              </Table.Tr>
            ))}
          </Table.Tbody>
        </Table>
      )}

      <CreateExtensionModal opened={modalOpen} onClose={() => setModalOpen(false)} />
      {callHandling && (
        // Keyed so switching rows resets the form rather than keeping the previous user's
        // forwarding numbers in the fields.
        <CallHandlingModal
          key={callHandling.id}
          extension={callHandling}
          onClose={() => setCallHandling(null)}
        />
      )}
    </Stack>
  );
}

export const Route = createFileRoute("/_app/extensions")({ component: Extensions });
