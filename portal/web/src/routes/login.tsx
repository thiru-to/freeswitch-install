/**
 * Sign in.
 *
 * The only route an anonymous visitor can reach. There is no registration link because there is
 * no self-service registration — accounts are created by an operator with
 * `src/cli/create-user.ts`, since a portal account administers telephony and a compromise means
 * toll fraud billed to a tenant.
 */
import { useState } from "react";
import { createFileRoute, redirect, useNavigate } from "@tanstack/react-router";
import {
  Alert,
  Button,
  Card,
  Center,
  PasswordInput,
  Stack,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import { authClient, ensureActiveOrganization } from "../lib/auth-client";

type LoginSearch = { redirect?: string };

export const Route = createFileRoute("/login")({
  /* Already signed in? Go to the app. Otherwise the browser back button after signing in lands
     on a login form that looks like the session was lost. */
  beforeLoad: async () => {
    const session = await authClient.getSession();
    if (session.data?.user) throw redirect({ to: "/" });
  },
  validateSearch: (search: Record<string, unknown>): LoginSearch => ({
    /* Only ever a path on this origin. An absolute URL here would turn the login page into an
       open redirect — attacker sends you a link to your own PBX, you sign in, and land on their
       site with your guard down. */
    redirect:
      typeof search.redirect === "string" && search.redirect.startsWith("/")
        ? search.redirect
        : undefined,
  }),
  component: Login,
});

function Login() {
  const navigate = useNavigate();
  const { redirect } = Route.useSearch();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);

    const result = await authClient.signIn.email({ email, password });

    if (result.error) {
      /* Deliberately not distinguishing "no such account" from "wrong password" — that
         difference tells an attacker which addresses are worth attacking. nginx also limits this
         path to 5 requests a minute per source address. */
      setError(
        result.error.status === 429
          ? "Too many attempts. Wait a minute and try again."
          : "Those credentials were not accepted.",
      );
      setBusy(false);
      return;
    }

    // A fresh session has no active organization; set it before the app mounts so the first page
    // does not fire a wave of 403s.
    await ensureActiveOrganization();
    await navigate({ to: redirect ?? "/" });
  }

  return (
    <Center h="100vh" px="md">
      <Card withBorder shadow="sm" p="xl" w={400} component="form" onSubmit={submit}>
        <Stack>
          <div>
            <Title order={3}>VoIP PBX</Title>
            <Text size="sm" c="dimmed">
              Sign in to the admin portal.
            </Text>
          </div>

          {error && (
            <Alert color="red" variant="light">
              {error}
            </Alert>
          )}

          <TextInput
            label="Email"
            type="email"
            autoComplete="username"
            value={email}
            onChange={(e) => setEmail(e.currentTarget.value)}
            required
            autoFocus
          />
          <PasswordInput
            label="Password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.currentTarget.value)}
            required
          />

          <Button type="submit" loading={busy} disabled={!email || !password} fullWidth>
            Sign in
          </Button>

          <Text size="xs" c="dimmed" ta="center">
            Accounts are created by your administrator.
          </Text>
        </Stack>
      </Card>
    </Center>
  );
}
