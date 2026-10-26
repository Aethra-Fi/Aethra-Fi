"use client";

import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { ChevronDown, Menu } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Sheet, SheetContent, SheetTitle, SheetTrigger } from "@/components/ui/sheet";
import { IndexerStatus } from "@/components/kit";
import { NETWORK, NETWORK_LABEL } from "@/lib/network";
import { cn } from "@/lib/utils";
import { MORE_NAV, PRIMARY_NAV } from "./nav";
import { ThemeToggle } from "./theme-toggle";

export function Logo({ className }: { className?: string }) {
  return (
    <Link href="/" className={cn("flex items-center gap-2.5", className)} aria-label="Aethra Fi home">
      <Image src="/brand/aethra-mark-64.png" alt="" width={24} height={24} priority />
      <span className="font-mono text-[13px] font-medium uppercase tracking-wordmark">Aethra</span>
    </Link>
  );
}

function isActive(pathname: string, href: string) {
  // /pools/create lives under "More", so it must not light up "Pools"
  if (href === "/pools") return pathname === "/pools" || (pathname.startsWith("/pools/") && pathname !== "/pools/create");
  return pathname === href || pathname.startsWith(`${href}/`);
}

/** RainbowKit connect flow rendered with Aethra buttons so it matches the rest of the UI. */
function WalletButton() {
  return (
    <ConnectButton.Custom>
      {({ account, chain, mounted, openAccountModal, openChainModal, openConnectModal }) => {
        if (!mounted) return <Button size="sm" className="invisible" aria-hidden>Connect wallet</Button>;
        if (!account || !chain) return <Button size="sm" onClick={openConnectModal}>Connect wallet</Button>;
        if (chain.unsupported) return <Button size="sm" variant="destructive" onClick={openChainModal}>Wrong network</Button>;
        return (
          <Button size="sm" variant="secondary" onClick={openAccountModal} className="normal-case tracking-normal">
            <span className="size-1.5 rounded-full bg-primary" />
            {account.displayName}
          </Button>
        );
      }}
    </ConnectButton.Custom>
  );
}

export function SiteHeader() {
  const pathname = usePathname();
  return (
    <header className="sticky top-0 z-40 border-b bg-bg/85 backdrop-blur supports-[backdrop-filter]:bg-bg/70">
      <div className="container flex h-14 items-center gap-6">
        <Logo />
        <nav className="hidden items-center gap-1 lg:flex" aria-label="Main">
          {PRIMARY_NAV.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                "rounded-sm px-3 py-2 font-mono text-[12px] uppercase tracking-button text-fg-2 transition-ui hover:text-fg",
                isActive(pathname, item.href) && "text-primary-text",
              )}
            >
              {item.label}
            </Link>
          ))}
          <DropdownMenu>
            <DropdownMenuTrigger className="flex items-center gap-1 rounded-sm px-3 py-2 font-mono text-[12px] uppercase tracking-button text-fg-2 transition-ui hover:text-fg">
              More <ChevronDown className="size-3.5" />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="start" className="w-64">
              {MORE_NAV.map((item) => (
                <DropdownMenuItem key={item.href} asChild>
                  <Link href={item.href} className="flex flex-col items-start gap-0.5">
                    <span className="text-sm">{item.label}</span>
                    <span className="text-xs text-muted">{item.description}</span>
                  </Link>
                </DropdownMenuItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>
        </nav>

        <div className="ml-auto flex items-center gap-2">
          <span className="hidden items-center gap-2 border px-2 py-1 font-mono text-[11px] uppercase tracking-eyebrow text-muted xl:flex">
            {NETWORK_LABEL[NETWORK]}
          </span>
          <IndexerStatus className="hidden md:flex" />
          <ThemeToggle />
          <WalletButton />
          <Sheet>
            <SheetTrigger asChild>
              <Button variant="ghost" size="icon-sm" className="lg:hidden" aria-label="Open menu">
                <Menu />
              </Button>
            </SheetTrigger>
            <SheetContent side="right" className="w-72">
              <SheetTitle className="sr-only">Menu</SheetTitle>
              <nav className="mt-8 flex flex-col" aria-label="Mobile">
                {[...PRIMARY_NAV, ...MORE_NAV].map((item) => (
                  <Link
                    key={item.href}
                    href={item.href}
                    className={cn(
                      "border-b py-3 font-mono text-[12px] uppercase tracking-button text-fg-2",
                      isActive(pathname, item.href) && "text-primary-text",
                    )}
                  >
                    {item.label}
                  </Link>
                ))}
              </nav>
            </SheetContent>
          </Sheet>
        </div>
      </div>
    </header>
  );
}
