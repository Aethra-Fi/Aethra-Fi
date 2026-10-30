import type { Metadata, Viewport } from "next";
import { GeistMono } from "geist/font/mono";
import { GeistSans } from "geist/font/sans";
import "@rainbow-me/rainbowkit/styles.css";
import "@/styles/globals.css";
import { CyberFx } from "@/components/fx/cyber-fx";
import { Providers } from "@/components/providers";
import { SiteFooter } from "@/components/layout/site-footer";
import { SiteHeader } from "@/components/layout/site-header";

export const metadata: Metadata = {
  title: { default: "Aethra Fi | Unified liquidity layer on Robinhood Chain", template: "%s · Aethra Fi" },
  description:
    "Aethra Fi is the unified liquidity layer on Robinhood Chain: smart-routed swaps, volatility-adaptive fees, DLMM limit orders and oracle-guarded stock pools.",
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL || "https://testnet.aethra.finance"),
};

export const viewport: Viewport = {
  themeColor: [{ color: "#0a0b0a" }],
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    // next-themes sets the class before paint; suppress the expected attribute mismatch
    <html lang="en" className={`dark ${GeistSans.variable} ${GeistMono.variable}`} suppressHydrationWarning>
      <body className="min-h-dvh bg-bg font-sans text-fg antialiased">
        <Providers>
          <div className="flex min-h-dvh flex-col">
            <SiteHeader />
            <main className="flex-1">{children}</main>
            <SiteFooter />
          </div>
        </Providers>
        <CyberFx />
      </body>
    </html>
  );
}
