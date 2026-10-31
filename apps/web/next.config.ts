import type { NextConfig } from "next";
import pkg from "./package.json";

const X402_MODULES = [
  "@x402/core/client",
  "@x402/core/server",
  "@x402/core/schemas",
  "@x402/evm",
  "@x402/evm/exact/client",
  "@x402/evm/exact/server",
  "@x402/evm/exact/v1/client",
  "@x402/evm/upto/client",
  "@x402/evm/upto/server",
  "@x402/evm/auth-capture/client",
  "@x402/evm/batch-settlement/client",
  "@x402/svm/exact/client",
  "@x402/svm/exact/server",
  "@x402/svm/exact/v1/client",
  "@x402/svm/upto/client",
  "@x402/svm/upto/server",
  "@x402/extensions/bazaar",
  "@x402/extensions/builder-code",
  "@x402/express",
  "@x402/fetch",
];

// No full CSP: wallet connectors load scripts and frames from many origins. frame-ancestors alone stops clickjacking.
const SECURITY_HEADERS = [
  { key: "Content-Security-Policy", value: "frame-ancestors 'none'" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), browsing-topics=()" },
];

const nextConfig: NextConfig = {
  reactStrictMode: true,
  env: { NEXT_PUBLIC_APP_VERSION: pkg.version },
  transpilePackages: ["@aethrafi/sdk"],
  poweredByHeader: false,
  images: { formats: ["image/avif", "image/webp"] },
  headers: async () => [{ source: "/:path*", headers: SECURITY_HEADERS }],
  webpack: (config) => {
    // WalletConnect / MetaMask SDK pull optional node-only deps; keep them out of the browser bundle.
    config.externals = [...(config.externals ?? []), "pino-pretty", "lokijs", "encoding"];
    return config;
  },
  turbopack: {
    resolveAlias: {
      "pino-pretty": { browser: "./src/lib/empty-module.ts" },
      lokijs: { browser: "./src/lib/empty-module.ts" },
      encoding: { browser: "./src/lib/empty-module.ts" },
      // optional x402 payment deps of @coinbase/cdp-sdk (pulled in via RainbowKit's Base Account); never used here
      ...Object.fromEntries(X402_MODULES.map((m) => [m, "./src/lib/x402-stub.ts"])),
    },
  },
};

export default nextConfig;
