import { createRootRoute, Link, Outlet, useRouterState } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import {
  AppShell,
  Badge,
  Group,
  NavLink,
  ScrollArea,
  Text,
  Title,
  Tooltip,
} from "@mantine/core";
import { endpoints, type Health } from "../lib/api";

/**
 * Health indicator in the shell.
 *
 * The API reports each dependency separately and that distinction is surfaced rather than
 * flattened: "Redis down" means calls are on the slow path but still working, whereas
 * "database down" means config changes fail. Collapsing both into "degraded" would hide the
 * difference at exactly the moment it matters.
 */
function HealthBadge() {
  const { data, isError } = useQuery<Health>({
    queryKey: ["health"],
    queryFn: () => endpoints.health(),
    refetchInterval: 30_000,
    retry: false,
  });

  if (isError || !data) {
    return (
      <Badge color="red" variant="light">
        API unreachable
      </Badge>
    );
  }

  const down = [
    !data.database && "database",
    !data.redis && "Redis",
    !data.freeswitch && "FreeSWITCH",
  ].filter(Boolean) as string[];

  if (down.length === 0) {
    return (
      <Badge color="green" variant="light">
        Healthy
      </Badge>
    );
  }

  return (
    <Tooltip label={`Unreachable: ${down.join(", ")}`}>
      <Badge color={data.database ? "yellow" : "red"} variant="light">
        Degraded — {down.join(", ")}
      </Badge>
    </Tooltip>
  );
}

const NAV = [
  { to: "/", label: "Dashboard" },
  { to: "/extensions", label: "Extensions" },
  { to: "/settings", label: "Settings" },
] as const;

function RootLayout() {
  const pathname = useRouterState({ select: (s) => s.location.pathname });

  return (
    <AppShell header={{ height: 56 }} navbar={{ width: 220, breakpoint: "sm" }} padding="md">
      <AppShell.Header>
        <Group h="100%" px="md" justify="space-between">
          <Title order={4}>VoIP PBX</Title>
          <HealthBadge />
        </Group>
      </AppShell.Header>

      <AppShell.Navbar p="xs">
        <ScrollArea>
          {NAV.map((item) => (
            <NavLink
              key={item.to}
              component={Link}
              to={item.to}
              label={item.label}
              active={pathname === item.to}
            />
          ))}
        </ScrollArea>
        <Text size="xs" c="dimmed" mt="auto" p="xs">
          Kamailio · FreeSWITCH · rtpengine
        </Text>
      </AppShell.Navbar>

      <AppShell.Main>
        <Outlet />
      </AppShell.Main>
    </AppShell>
  );
}

export const Route = createRootRoute({ component: RootLayout });
