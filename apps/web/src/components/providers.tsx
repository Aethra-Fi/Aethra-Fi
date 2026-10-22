"use client";

import * as React from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RainbowKitProvider } from "@rainbow-me/rainbowkit";
import { ThemeProvider, useTheme } from "next-themes";
import { WagmiProvider } from "wagmi";
import { TooltipProvider } from "@/components/ui/tooltip";
import { ApiError } from "@/lib/api";
import { CHAIN } from "@/lib/network";
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
            <TooltipProvider delayDuration={150}>{children}</TooltipProvider>
          </RainbowThemed>
        </QueryClientProvider>
      </WagmiProvider>
    </ThemeProvider>
  );
}
