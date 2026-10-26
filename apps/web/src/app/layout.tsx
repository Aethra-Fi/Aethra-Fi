import type { Metadata, Viewport } from "next";
import { GeistMono } from "geist/font/mono";
import { GeistSans } from "geist/font/sans";
import "@rainbow-me/rainbowkit/styles.css";
import "@/styles/globals.css";
import { Providers } from "@/components/providers";
import { SiteFooter } from "@/components/layout/site-footer";
import { SiteHeader } from "@/components/layout/site-header";

export const metadata: Metadata = {
  title: { default: "Aethra Fi: liquidity layer on Robinhood Chain", template: "%s · Aethra Fi" },
  description:
    "Swap and provide liquidity on Robinhood Chain. Dynamic-fee and oracle-guarded pools across v4, DLMM and DAMM venues.",
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL || "https://aethra-fi-testnet.vercel.app"),
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
      </body>
    </html>
  );
}
