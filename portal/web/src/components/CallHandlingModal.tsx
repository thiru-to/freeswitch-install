/**
 * Per-user call handling: DND, the three forwards, ring time and call waiting.
 *
 * The same settings users change from their handset with *78 and *72, so the feature codes are
 * printed alongside each control. Someone reading this dialog is often on the phone to the user
 * who set something by accident and cannot remember how - having the code in front of them is
 * the difference between fixing it and guessing.
 */
import { useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import {
  Button,
  Code,
  Divider,
  Group,
  Modal,
  NumberInput,
  Stack,
  Switch,
  Text,
  TextInput,
} from "@mantine/core";
import { endpoints, type Extension } from "../lib/api";
import { ErrorAlert } from "./Resource";

function ForwardField({
  label,
  code,
  clearCode,
  value,
  onChange,
  description,
}: {
  label: string;
  code: string;
  clearCode: string;
  value: string;
  onChange: (v: string) => void;
  description: string;
}) {
  return (
    <TextInput
      label={
        <Group gap={6}>
          <span>{label}</span>
          <Code>{code}</Code>
          <Text size="xs" c="dimmed">
            clear with <Code>{clearCode}</Code>
          </Text>
        </Group>
      }
      description={description}
      placeholder="Leave blank for none"
      value={value}
      onChange={(e) => onChange(e.currentTarget.value)}
    />
  );
}

export function CallHandlingModal({
  extension,
  onClose,
}: {
  extension: Extension;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const [dnd, setDnd] = useState(extension.dnd);
  const [callWaiting, setCallWaiting] = useState(extension.callWaitingEnabled);
  const [ringTimeout, setRingTimeout] = useState<number | string>(extension.ringTimeoutSec ?? "");
  const [fwdAll, setFwdAll] = useState(extension.forwardAllTo ?? "");
  const [fwdBusy, setFwdBusy] = useState(extension.forwardBusyTo ?? "");
  const [fwdNa, setFwdNa] = useState(extension.forwardNoAnswerTo ?? "");

  const save = useMutation({
    mutationFn: () =>
      endpoints.updateExtension(extension.id, {
        dnd,
        callWaitingEnabled: callWaiting,
        // Empty means "inherit the tenant default", which is not the same as zero.
        ringTimeoutSec: ringTimeout === "" ? null : Number(ringTimeout),
        forwardAllTo: fwdAll || null,
        forwardBusyTo: fwdBusy || null,
        forwardNoAnswerTo: fwdNa || null,
      }),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["extensions"] });
      onClose();
    },
  });

  return (
    <Modal
      opened
      onClose={onClose}
      title={`Call handling — ${extension.number} ${extension.displayName}`}
      size="lg"
    >
      <Stack>
        <ErrorAlert error={save.error} />

        <Switch
          label={
            <Group gap={6}>
              <span>Do not disturb</span>
              <Code>*78</Code>
              <Text size="xs" c="dimmed">
                off with <Code>*79</Code>
              </Text>
            </Group>
          }
          description="The phone does not ring. Callers still reach the no-answer treatment below."
          checked={dnd}
          onChange={(e) => setDnd(e.currentTarget.checked)}
        />

        <Switch
          label="Call waiting"
          description="Off sends a second simultaneous call to the busy treatment instead of ringing again."
          checked={callWaiting}
          onChange={(e) => setCallWaiting(e.currentTarget.checked)}
        />

        <NumberInput
          label="Ring for (seconds)"
          description="Blank inherits the tenant default"
          value={ringTimeout}
          onChange={setRingTimeout}
          min={5}
          max={120}
        />

        <Divider label="Forwarding" labelPosition="left" />

        <ForwardField
          label="All calls"
          code="*72"
          clearCode="*73"
          value={fwdAll}
          onChange={setFwdAll}
          description="Overrides everything else, including do not disturb — the phone never rings."
        />
        <ForwardField
          label="When busy"
          code="*90"
          clearCode="*91"
          value={fwdBusy}
          onChange={setFwdBusy}
          description="Also used when call waiting is off and a call is already up."
        />
        <ForwardField
          label="When there is no answer"
          code="*92"
          clearCode="*93"
          value={fwdNa}
          onChange={setFwdNa}
          description="Takes precedence over voicemail. Also used when do not disturb is on."
        />

        <Text size="xs" c="dimmed">
          Forward targets are dialled the way a user would dial them, and go out through the
          tenant's own outbound routes.
        </Text>

        <Group justify="flex-end">
          <Button variant="subtle" onClick={onClose}>
            Cancel
          </Button>
          <Button onClick={() => save.mutate()} loading={save.isPending}>
            Save
          </Button>
        </Group>
      </Stack>
    </Modal>
  );
}
