import type { NextConfig } from "next";

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

const nextConfig: NextConfig = {
  reactStrictMode: true,
  transpilePackages: ["@aethrafi/sdk"],
  poweredByHeader: false,
  images: { formats: ["image/avif", "image/webp"] },
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
