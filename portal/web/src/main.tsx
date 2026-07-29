import { StrictMode } from "react";
import ReactDOM from "react-dom/client";
import { RouterProvider, createRouter } from "@tanstack/react-router";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MantineProvider } from "@mantine/core";

import "@mantine/core/styles.css";
import { routeTree } from "./routeTree.gen";
import { theme } from "./theme";

/**
 * Query defaults tuned for an operations console.
 *
 * Telephony config changes rarely, so a short stale time avoids hammering the API while
 * someone reads a page. Refetch-on-focus is deliberately left ON: returning to a tab during an
 * incident should show current state, not what was true ten minutes ago.
 */
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      refetchOnWindowFocus: true,
      /**
       * Try regardless of what the browser thinks about connectivity.
       *
       * The default (`networkMode: "online"`) parks a query in `fetchStatus: "paused"` whenever
       * the online-manager believes there is no network - it never runs, never errors, and the
       * UI sits on a spinner with nothing to explain it. That was observed here with
       * `navigator.onLine === true`, which is the point: onLine is a guess about whether any
       * interface is up, not about whether this API is reachable.
       *
       * The API is same-origin on the operator's own network. Attempting and failing gives them
       * a message; refusing to attempt gives them a spinner.
       */
      networkMode: "always",
      // A 401 or 403 will not resolve by trying again - only network and 5xx are worth a retry.
      retry: (failureCount, error) => {
        const status = (error as { status?: number })?.status;
        if (status && status >= 400 && status < 500) return false;
        return failureCount < 2;
      },
    },
    // Same reasoning: a config change that silently refuses to be sent is worse than one that
    // fails and says so.
    mutations: { networkMode: "always" },
  },
});

const router = createRouter({ routeTree });

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}

const rootElement = document.getElementById("root")!;
if (!rootElement.innerHTML) {
  ReactDOM.createRoot(rootElement).render(
    <StrictMode>
      <MantineProvider theme={theme} defaultColorScheme="auto">
        <QueryClientProvider client={queryClient}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      </MantineProvider>
    </StrictMode>,
  );
}
