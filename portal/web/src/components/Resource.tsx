/**
 * Shared page furniture for the resource screens.
 *
 * Extracted because four pages otherwise repeat the same loading/error/empty handling, and the
 * error case is the one that matters: the API rejects cross-tenant references and invalid
 * patterns with a 400 and a specific message, and swallowing that into "something went wrong"
 * would leave someone guessing at a rule the server is willing to explain.
 */
import type { ReactNode } from "react";
import { Alert, Button, Center, Group, Loader, Stack, Text, Title } from "@mantine/core";
import { ApiError } from "../lib/api";

export function PageHeader({
  title,
  description,
  action,
}: {
  title: string;
  description?: string;
  action?: ReactNode;
}) {
  return (
    <Group justify="space-between" align="flex-start" mb="md">
      <div>
        <Title order={3}>{title}</Title>
        {description && (
          <Text size="sm" c="dimmed" mt={4}>
            {description}
          </Text>
        )}
      </div>
      {action}
    </Group>
  );
}

/** Surfaces the API's own message. See the note at the top of this file. */
export function ErrorAlert({ error, title }: { error: unknown; title?: string }) {
  if (!error) return null;
  const api = error instanceof ApiError ? error : null;
  return (
    <Alert color="red" title={title ?? (api ? `Rejected (${api.status})` : "Error")} mb="md">
      <Stack gap={4}>
        <Text size="sm">{(error as Error).message}</Text>
        {api?.detail && (
          <Text size="xs" c="dimmed">
            {api.detail}
          </Text>
        )}
      </Stack>
    </Alert>
  );
}

/**
 * Loading / error / empty for a list query.
 *
 * **Callers must destructure the query in their own render and pass these as separate props.**
 * Passing the whole `useQuery` result object through does not work: React Query v5 tracks which
 * result properties a component reads *during that component's render* and only re-renders it
 * when those change. Handing the object to a child means the parent only ever touches `data`,
 * never subscribes to `error` or `isPending`, and the page stays frozen on the spinner while
 * the query sits in an error state behind it.
 *
 * `isSuccess` rather than a caller-computed `isEmpty` for the same reason the props are split:
 * `(data ?? []).length === 0` is true while data is still undefined, so a failed fetch rendered
 * "No trunks yet" and told an operator a tenant had nothing configured when in fact the API was
 * unreachable. Emptiness can only be claimed when the API actually answered.
 */
export function QueryState<T>({
  data,
  error,
  isPending,
  isSuccess,
  isPaused,
  emptyMessage,
  emptyAction,
  children,
}: {
  data: T[] | undefined;
  error: unknown;
  isPending: boolean;
  isSuccess: boolean;
  /** True when React Query has parked the fetch instead of running it. */
  isPaused?: boolean;
  emptyMessage: string;
  emptyAction?: ReactNode;
  children: ReactNode;
}) {
  // Error first: a query that failed after retries is not "still loading", and a spinner that
  // never resolves is how a broken page disguises itself as a slow one.
  if (error) return <ErrorAlert error={error} />;

  /* A paused query is pending and will stay pending - no request is in flight and none is
     scheduled. networkMode: "always" in main.tsx should mean this never happens, but if it
     ever does, say so instead of spinning for ever. */
  if (isPaused) {
    return (
      <Alert color="yellow" title="Waiting for a connection" mb="md">
        The browser reports no network, so the request has not been sent. It will run as soon as
        connectivity returns.
      </Alert>
    );
  }

  if (isPending) {
    return (
      <Center py="xl">
        <Loader />
      </Center>
    );
  }

  if (isSuccess && (data ?? []).length === 0) {
    return (
      <Center py="xl">
        <Stack align="center" gap="sm">
          <Text c="dimmed">{emptyMessage}</Text>
          {emptyAction}
        </Stack>
      </Center>
    );
  }

  return <>{children}</>;
}

/**
 * Delete confirmation.
 *
 * A plain confirm() would do, but these deletes cascade into live call routing - removing a
 * ring group an inbound route points at changes what happens to the next call - so the name is
 * repeated back rather than relying on someone reading a generic prompt.
 */
export function DeleteButton({
  what,
  onConfirm,
  loading,
}: {
  what: string;
  onConfirm: () => void;
  loading?: boolean;
}) {
  return (
    <Button
      size="xs"
      variant="subtle"
      color="red"
      loading={loading}
      onClick={() => {
        if (window.confirm(`Delete ${what}? Anything routing to it will stop working.`)) {
          onConfirm();
        }
      }}
    >
      Delete
    </Button>
  );
}
