import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  transpilePackages: ["@aethra/sdk"],
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
    },
  },
};

export default nextConfig;
