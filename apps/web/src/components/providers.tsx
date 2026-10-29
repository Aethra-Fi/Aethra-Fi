"use client";

import * as React from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RainbowKitProvider } from "@rainbow-me/rainbowkit";
import { ThemeProvider, useTheme } from "next-themes";
import { WagmiProvider } from "wagmi";
import { TooltipProvider } from "@/components/ui/tooltip";
import { ApiError } from "@/lib/api";
import { CHAIN, restoreNetwork, useNetwork } from "@/lib/network";
import { rainbowTheme } from "@/lib/rainbow-theme";
import { getWagmiConfig } from "@/lib/wagmi";

function RainbowThemed({ children }: { children: React.ReactNode }) {
  const { resolvedTheme } = useTheme();
  const theme = React.useMemo(() => rainbowTheme(resolvedTheme === "light" ? "light" : "dark"), [resolvedTheme]);
  return (
    <RainbowKitProvider theme={theme} initialChain={CHAIN} modalSize="compact" appInfo={{ appName: "Aethra Fi" }}>
      {children}
    </RainbowKitProvider>
  );
}

/**
 * Re-mounts the app when the network changes, so every component re-reads the active chain, deployment and API.
 * The saved choice is applied after hydration (the server and the first render always use the default network).
 */
function NetworkScope({ children }: { children: React.ReactNode }) {
  const network = useNetwork();
  React.useEffect(() => restoreNetwork(), []);
  return <React.Fragment key={network}>{children}</React.Fragment>;
}

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = React.useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 15_000,
            refetchOnWindowFocus: false,
            // an offline indexer should fail fast into the "Indexer offline" state
            retry: (count, err) => !(err instanceof ApiError && err.offline) && count < 1,
          },
        },
      }),
  );
  return (
    <ThemeProvider attribute="class" defaultTheme="dark" enableSystem={false} storageKey="aethra-theme" disableTransitionOnChange>
      <WagmiProvider config={getWagmiConfig()}>
        <QueryClientProvider client={queryClient}>
          <RainbowThemed>
            <TooltipProvider delayDuration={150}>
              <NetworkScope>{children}</NetworkScope>
            </TooltipProvider>
          </RainbowThemed>
        </QueryClientProvider>
      </WagmiProvider>
    </ThemeProvider>
  );
}
