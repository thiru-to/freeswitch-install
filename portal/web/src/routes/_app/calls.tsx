import { useState } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import {
  Badge,
  Button,
  Card,
  Group,
  Pagination,
  Select,
  SimpleGrid,
  Table,
  Text,
  TextInput,
} from "@mantine/core";
import { endpoints, type Cdr, type CdrFilters } from "../../lib/api";
import { PageHeader, QueryState } from "../../components/Resource";

const PAGE_SIZE = 50;

function formatDuration(sec: number): string {
  if (sec <= 0) return "—";
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return m > 0 ? `${m}m ${s}s` : `${s}s`;
}

function directionColour(d: Cdr["direction"]): string {
  return d === "inbound" ? "blue" : d === "outbound" ? "grape" : "gray";
}

function SummaryCards({ from, to }: { from?: string; to?: string }) {
  const { data } = useQuery({
    queryKey: ["cdr-summary", from, to],
    queryFn: () => endpoints.cdrSummary(from, to),
  });

  const cards = [
    { label: "Calls", value: data ? String(data.calls) : "—" },
    {
      label: "Answered",
      // Null rather than 0% when there are no calls: "0% answered" reads like a fault, and a
      // brand-new tenant with no traffic is not one.
      value:
        data == null
          ? "—"
          : data.answerRate === null
            ? "—"
            : `${Math.round(data.answerRate * 100)}%`,
    },
    { label: "Inbound", value: data ? String(data.inbound) : "—" },
    { label: "Outbound", value: data ? String(data.outbound) : "—" },
    { label: "Billable", value: data ? formatDuration(data.billableSec) : "—" },
  ];

  return (
    <SimpleGrid cols={{ base: 2, sm: 3, md: 5 }} mb="md">
      {cards.map((c) => (
        <Card key={c.label} withBorder padding="sm">
          <Text size="xs" c="dimmed">
            {c.label}
          </Text>
          <Text size="xl" fw={600}>
            {c.value}
          </Text>
        </Card>
      ))}
    </SimpleGrid>
  );
}

function CallsPage() {
  const [direction, setDirection] = useState("");
  const [number, setNumber] = useState("");
  const [answered, setAnswered] = useState("");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [page, setPage] = useState(1);

  const filters: CdrFilters = {
    direction: direction || undefined,
    number: number || undefined,
    answered: answered || undefined,
    from: from || undefined,
    to: to || undefined,
    limit: PAGE_SIZE,
    offset: (page - 1) * PAGE_SIZE,
  };

  const { data, isPending, isSuccess, isPaused, error } = useQuery({
    queryKey: ["cdr", filters],
    queryFn: () => endpoints.cdr(filters),
    // Keeps the previous page on screen while the next loads, so paging does not flash empty.
    placeholderData: keepPreviousData,
  });

  const pages = Math.max(1, Math.ceil((data?.total ?? 0) / PAGE_SIZE));

  // Any filter change invalidates the current page number - staying on page 7 of a result set
  // that now has two pages shows nothing and looks broken.
  const resetPage = <T,>(setter: (v: T) => void) => (v: T) => {
    setter(v);
    setPage(1);
  };

  return (
    <>
      <PageHeader
        title="Calls"
        description="Every call FreeSWITCH handled. Read-only by design — a phone system whose billing history can be edited through its own API is not one anyone should buy."
      />

      <SummaryCards from={from || undefined} to={to || undefined} />

      <Group mb="md" align="flex-end">
        <TextInput
          label="Number"
          placeholder="Caller or destination"
          value={number}
          onChange={(e) => resetPage(setNumber)(e.currentTarget.value)}
        />
        <Select
          label="Direction"
          data={[
            { value: "", label: "Any" },
            { value: "inbound", label: "Inbound" },
            { value: "outbound", label: "Outbound" },
            { value: "internal", label: "Internal" },
          ]}
          value={direction}
          onChange={(v) => resetPage(setDirection)(v ?? "")}
          w={140}
        />
        <Select
          label="Answered"
          data={[
            { value: "", label: "Any" },
            { value: "true", label: "Answered" },
            { value: "false", label: "Missed" },
          ]}
          value={answered}
          onChange={(v) => resetPage(setAnswered)(v ?? "")}
          w={140}
        />
        <TextInput
          label="From"
          type="date"
          value={from}
          onChange={(e) => resetPage(setFrom)(e.currentTarget.value)}
        />
        <TextInput
          label="To"
          type="date"
          value={to}
          onChange={(e) => resetPage(setTo)(e.currentTarget.value)}
        />
        {(number || direction || answered || from || to) && (
          <Button
            variant="subtle"
            onClick={() => {
              setNumber("");
              setDirection("");
              setAnswered("");
              setFrom("");
              setTo("");
              setPage(1);
            }}
          >
            Clear
          </Button>
        )}
      </Group>

      {/* The CDR endpoint returns a page object rather than an array, so only the row list is
          handed over for the emptiness check. */}
      <QueryState
        data={data?.rows}
        error={error}
        isPending={isPending}
        isSuccess={isSuccess}
        isPaused={isPaused}
        emptyMessage="No calls match."
      >
        <Table striped highlightOnHover>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Started</Table.Th>
              <Table.Th>Direction</Table.Th>
              <Table.Th>From</Table.Th>
              <Table.Th>To</Table.Th>
              <Table.Th>Extension</Table.Th>
              <Table.Th>Duration</Table.Th>
              <Table.Th>Result</Table.Th>
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {(data?.rows ?? []).map((r) => (
              <Table.Tr key={r.id}>
                <Table.Td>
                  <Text size="sm">{new Date(r.startedAt).toLocaleString()}</Text>
                </Table.Td>
                <Table.Td>
                  <Badge variant="light" color={directionColour(r.direction)}>
                    {r.direction}
                  </Badge>
                </Table.Td>
                <Table.Td>
                  <Text size="sm">{r.callerNumber ?? "—"}</Text>
                  {r.callerName && r.callerName !== r.callerNumber && (
                    <Text size="xs" c="dimmed">
                      {r.callerName}
                    </Text>
                  )}
                </Table.Td>
                <Table.Td>{r.destinationNumber}</Table.Td>
                <Table.Td>
                  <Text size="sm">{r.extensionNumber ?? r.trunkName ?? "—"}</Text>
                </Table.Td>
                <Table.Td>
                  {/* Billable seconds, not wall clock: ring time is not a call. The total is
                      shown underneath so a long ring is still visible. */}
                  <Text size="sm">{formatDuration(r.billsecSec)}</Text>
                  {r.durationSec > r.billsecSec && (
                    <Text size="xs" c="dimmed">
                      {formatDuration(r.durationSec)} total
                    </Text>
                  )}
                </Table.Td>
                <Table.Td>
                  {r.answeredAt ? (
                    <Badge variant="light" color="green">
                      answered
                    </Badge>
                  ) : (
                    <Badge variant="light" color="orange">
                      {r.hangupCause ?? "no answer"}
                    </Badge>
                  )}
                </Table.Td>
              </Table.Tr>
            ))}
          </Table.Tbody>
        </Table>

        {pages > 1 && (
          <Group justify="space-between" mt="md">
            <Text size="sm" c="dimmed">
              {data?.total} calls
            </Text>
            <Pagination value={page} onChange={setPage} total={pages} />
          </Group>
        )}
      </QueryState>
    </>
  );
}

export const Route = createFileRoute("/_app/calls")({ component: CallsPage });
