/**
 * The authenticated part of the portal.
 *
 * A pathless layout route, so every page under `_app/` inherits the guard below and nothing
 * renders — not the shell, not the navigation, not even the page names — until there is a
 * session. Before this existed the whole console was visible to anyone who found the hostname;
 * only the data was protected, by the API returning 401.
 *
 * nginx returns 404 for these paths to anonymous visitors as well (steps/42-nginx.sh). This guard
 * is the client-side half: it is what handles a session that expires while the tab is open, and
 * what makes the redirect land somewhere useful instead of a bare 404.
 */
import { createFileRoute, Link, Outlet, redirect, useRouterState } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import {
  Alert,
  AppShell,
  Badge,
  Button,
  Code,
  Group,
  Menu,
  NavLink,
  ScrollArea,
  Stack,
  Text,
  Title,
  Tooltip,
} from "@mantine/core";
import { authClient, ensureActiveOrganization } from "../lib/auth-client";
import { endpoints, type Health } from "../lib/api";

export const Route = createFileRoute("/_app")({
  /**
   * Runs before any child route renders, including on a direct deep link.
   *
   * `getSession` rather than the `useSession` hook, because this has to resolve before the page
   * mounts — a hook would flash the console for a frame before redirecting, which is exactly the
   * exposure this route exists to prevent. The server's cookie cache (5 minutes, set in
   * auth.ts) keeps this off the database on most navigations.
   */
  beforeLoad: async ({ location }) => {
    const session = await authClient.getSession();
    if (!session.data?.user) {
      throw redirect({
        to: "/login",
        // So a deep link survives the round trip through sign-in.
        search: { redirect: location.href },
      });
    }
  },
  component: AppLayout,
});

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

function AccountMenu() {
  const { data: session } = authClient.useSession();
  const email = session?.user.email ?? "";

  return (
    <Menu position="bottom-end" withinPortal>
      <Menu.Target>
        <Button variant="subtle" size="compact-sm">
          {email}
        </Button>
      </Menu.Target>
      <Menu.Dropdown>
        <Menu.Item
          onClick={async () => {
            await authClient.signOut();
            // Full reload rather than a router navigation: it drops the React Query cache with
            // the session, so the next user of this browser cannot see the previous tenant's
            // data flash on screen before the refetch.
            window.location.href = "/login";
          }}
        >
          Sign out
        </Menu.Item>
      </Menu.Dropdown>
    </Menu>
  );
}

/* Ordered the way a call travels: it arrives on a trunk, a route decides where it lands, a
   call flow answers it, and the result shows up in Calls. */
const NAV = [
  { to: "/", label: "Dashboard" },
  { to: "/extensions", label: "Extensions" },
  { to: "/trunks", label: "Trunks" },
  { to: "/routing", label: "Routing" },
  { to: "/call-flows", label: "Call flows" },
  { to: "/calls", label: "Calls" },
  { to: "/settings", label: "Settings" },
] as const;

/**
 * Shown when the account exists but belongs to no organization.
 *
 * A real state rather than an error: `provision-tenant.ts` has not been run for this user yet.
 * Worth its own panel because the alternative is every page on the dashboard returning 403,
 * which reads as a broken system rather than an unfinished setup.
 */
function NoTenant({ email }: { email: string }) {
  return (
    <Alert color="yellow" title="No tenant assigned to this account">
      <Stack gap="sm">
        <Text size="sm">
          <Code>{email}</Code> can sign in but is not a member of any organization, so there is no
          telephony configuration to show. Tenants are provisioned by an operator, not
          self-served.
        </Text>
        <Text size="sm">On the server, run:</Text>
        <Code block>
          {`cd /opt/voip-api\nsudo -u voipapi bun run src/cli/provision-tenant.ts \\\n  --name "Acme Corp" --slug acme \\\n  --domain <sip-domain> --owner ${email}`}
        </Code>
        <Text size="xs" c="dimmed">
          Then sign out and back in.
        </Text>
      </Stack>
    </Alert>
  );
}

function AppLayout() {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const { data: session } = authClient.useSession();

  /* Every API call is scoped by the session's active organization, and a session restored from a
     cookie on a fresh page load has none set — so this runs on entry rather than only after
     sign-in. Without it a reload leaves every panel returning 403. */
  const org = useQuery({
    queryKey: ["active-organization", session?.user.id],
    queryFn: ensureActiveOrganization,
    enabled: Boolean(session?.user),
    staleTime: Infinity,
    retry: false,
  });

  return (
    <AppShell header={{ height: 56 }} navbar={{ width: 220, breakpoint: "sm" }} padding="md">
      <AppShell.Header>
        <Group h="100%" px="md" justify="space-between">
          <Title order={4}>VoIP PBX</Title>
          <Group gap="sm">
            <HealthBadge />
            <AccountMenu />
          </Group>
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
        {/* Held until the organization question is settled, so pages do not mount and fire a
            wave of 403s against a session that is one request away from being scoped. */}
        {org.isSuccess && org.data === false ? (
          <NoTenant email={session?.user.email ?? ""} />
        ) : org.isSuccess ? (
          <Outlet />
        ) : null}
      </AppShell.Main>
    </AppShell>
  );
}
