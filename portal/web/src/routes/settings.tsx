import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { Alert, Badge, Group, Loader, Stack, Table, Text, Title } from "@mantine/core";
import { endpoints, ApiError, type TenantSettings } from "../lib/api";

function Row({ label, value, hint }: { label: string; value: React.ReactNode; hint?: string }) {
  return (
    <Table.Tr>
      <Table.Td w={220}>
        <Text size="sm" fw={500}>
          {label}
        </Text>
        {hint ? (
          <Text size="xs" c="dimmed">
            {hint}
          </Text>
        ) : null}
      </Table.Td>
      <Table.Td>{value}</Table.Td>
    </Table.Tr>
  );
}

function Settings() {
  const { data, isLoading, error } = useQuery<TenantSettings>({
    queryKey: ["tenant"],
    queryFn: () => endpoints.tenant(),
    retry: false,
  });

  if (isLoading) {
    return (
      <Group justify="center" p="xl">
        <Loader />
      </Group>
    );
  }

  if (error instanceof ApiError && error.status === 404) {
    return <Alert color="yellow">Telephony is not provisioned for this organization.</Alert>;
  }
  if (error) {
    return <Alert color="red">{(error as Error).message}</Alert>;
  }
  if (!data) return null;

  return (
    <Stack>
      <Title order={3}>Settings</Title>

      <Table>
        <Table.Tbody>
          <Row
            label="SIP domain"
            hint="the tenancy boundary at the SIP layer"
            value={<Text ff="monospace">{data.sipDomain}</Text>}
          />
          <Row
            label="Tier"
            hint="shared pool, or pinned to dedicated nodes"
            value={<Badge variant="light">{data.tier}</Badge>}
          />
          <Row
            label="Dispatcher set"
            hint="which FreeSWITCH pool carries this tenant"
            value={<Text ff="monospace">{data.dispatcherSetId}</Text>}
          />
          <Row
            label="Egress mode"
            hint="proxied routes outbound calls through Kamailio"
            value={<Badge variant="light">{data.egressMode}</Badge>}
          />
          <Row
            label="Concurrent call limit"
            hint="the toll-fraud ceiling — a stolen credential cannot exceed this"
            value={<Text ff="monospace">{data.maxConcurrentCalls}</Text>}
          />
          <Row
            label="STIR/SHAKEN"
            value={
              <Badge color={data.stirShakenEnabled ? "green" : "gray"} variant="light">
                {data.stirShakenEnabled ? "enabled" : "disabled"}
              </Badge>
            }
          />
          <Row
            label="Recording"
            value={<Badge variant="light">{data.recordingPolicy}</Badge>}
          />
          <Row label="Timezone" value={<Text ff="monospace">{data.timezone}</Text>} />
          <Row
            label="Default caller ID"
            value={
              <Text ff="monospace">
                {data.defaultCallerIdName ?? "—"} &lt;{data.defaultCallerIdNumber ?? "—"}&gt;
              </Text>
            }
          />
        </Table.Tbody>
      </Table>
    </Stack>
  );
}

export const Route = createFileRoute("/settings")({ component: Settings });
