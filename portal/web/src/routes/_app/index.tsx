import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { Alert, Card, Grid, Group, Loader, Stack, Text, Title } from "@mantine/core";
import { endpoints, ApiError, type Extension, type TenantSettings } from "../../lib/api";

function Stat({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <Card withBorder padding="md">
      <Text size="xs" c="dimmed" tt="uppercase">
        {label}
      </Text>
      <Text size="xl" fw={600} ff="monospace">
        {value}
      </Text>
      {hint ? (
        <Text size="xs" c="dimmed">
          {hint}
        </Text>
      ) : null}
    </Card>
  );
}

function Dashboard() {
  const tenant = useQuery<TenantSettings>({
    queryKey: ["tenant"],
    queryFn: () => endpoints.tenant(),
    retry: false,
  });
  const extensions = useQuery<Extension[]>({
    queryKey: ["extensions"],
    queryFn: () => endpoints.extensions(),
    retry: false,
  });

  /**
   * A 404 on the tenant is not a failure — it means the organization exists but telephony has
   * not been provisioned. Saying so names the next action, which a generic error would not.
   */
  if (tenant.error instanceof ApiError && tenant.error.status === 404) {
    return (
      <Alert color="yellow" title="Telephony is not provisioned for this organization">
        <Stack gap="xs">
          <Text size="sm">
            Create the tenant settings with a SIP domain before adding extensions — Kamailio
            needs the domain to exist before any endpoint can register into it.
          </Text>
          <Text size="sm" ff="monospace">
            POST /api/tenant {'{ "sipDomain": "customer.example.com" }'}
          </Text>
        </Stack>
      </Alert>
    );
  }

  if (tenant.isLoading || extensions.isLoading) {
    return (
      <Group justify="center" p="xl">
        <Loader />
      </Group>
    );
  }

  if (tenant.error) {
    return (
      <Alert color="red" title="Could not load tenant">
        {(tenant.error as Error).message}
      </Alert>
    );
  }

  const rows = extensions.data ?? [];
  const enabled = rows.filter((e) => e.enabled).length;

  return (
    <Stack>
      <Title order={3}>Dashboard</Title>

      <Grid>
        <Grid.Col span={{ base: 12, sm: 6, md: 3 }}>
          <Stat label="SIP domain" value={tenant.data?.sipDomain ?? "—"} />
        </Grid.Col>
        <Grid.Col span={{ base: 12, sm: 6, md: 3 }}>
          <Stat label="Extensions" value={String(rows.length)} hint={`${enabled} enabled`} />
        </Grid.Col>
        <Grid.Col span={{ base: 12, sm: 6, md: 3 }}>
          <Stat
            label="Concurrent limit"
            value={String(tenant.data?.maxConcurrentCalls ?? "—")}
            hint="per tenant, toll-fraud cap"
          />
        </Grid.Col>
        <Grid.Col span={{ base: 12, sm: 6, md: 3 }}>
          <Stat
            label="Tier"
            value={tenant.data?.tier ?? "—"}
            hint={`dispatcher set ${tenant.data?.dispatcherSetId ?? "—"}`}
          />
        </Grid.Col>
      </Grid>
    </Stack>
  );
}

export const Route = createFileRoute("/_app/")({ component: Dashboard });
