import { afterEach, describe, expect, it, vi } from "vitest";

async function load(env: Record<string, string>) {
  vi.resetModules();
  for (const [k, v] of Object.entries(env)) vi.stubEnv(k, v);
  return import("@/lib/network");
}

afterEach(() => vi.unstubAllEnvs());

describe("network switching", () => {
  it("a testnet build offers testnet and mainnet", async () => {
    const n = await load({ NEXT_PUBLIC_NETWORK: "testnet" });
    expect(n.DEFAULT_NETWORK).toBe("testnet");
    expect([...n.SELECTABLE_NETWORKS]).toEqual(["testnet", "mainnet"]);
    expect(n.CHAIN_ID).toBe(46630);
  });

  it("mainnet is selectable only once its contracts are published", async () => {
    const n = await load({ NEXT_PUBLIC_NETWORK: "testnet" });
    expect(n.isSelectable("mainnet")).toBe(n.isDeployed("mainnet"));
    expect(n.isSelectable("testnet")).toBe(true);
    const ok = n.setNetwork("mainnet");
    expect(ok).toBe(n.isDeployed("mainnet"));
    expect(n.NETWORK).toBe(ok ? "mainnet" : "testnet");
  });

  it("an unavailable network never changes the live bindings", async () => {
    const n = await load({ NEXT_PUBLIC_NETWORK: "testnet" });
    if (n.isDeployed("mainnet")) return; // covered by the next test once mainnet ships
    n.setNetwork("mainnet");
    expect(n.NETWORK).toBe("testnet");
    expect(n.CHAIN_ID).toBe(46630);
    expect(n.API_URL).toBe(n.apiUrlFor("testnet"));
  });

  it("switching to a deployed network updates chain, deployment and API together", async () => {
    // pretend the build starts on mainnet and testnet is the other option
    const n = await load({ NEXT_PUBLIC_NETWORK: "mainnet" });
    expect(n.NETWORK).toBe("mainnet");
    expect(n.CHAIN_ID).toBe(4663);
    expect(n.setNetwork("testnet")).toBe(true);
    expect(n.NETWORK).toBe("testnet");
    expect(n.CHAIN_ID).toBe(46630);
    expect(n.DEPLOYMENT.hub).not.toBeNull();
    expect(n.API_URL).toBe(n.apiUrlFor("testnet"));
    expect(n.explorerTx("0xabc")).toBe("https://explorer.testnet.chain.robinhood.com/tx/0xabc");
  });

  it("each network has its own API; the legacy variable only overrides the default network", async () => {
    const n = await load({ NEXT_PUBLIC_NETWORK: "testnet", NEXT_PUBLIC_API_URL: "https://override.example/api/" });
    expect(n.apiUrlFor("testnet")).toBe("https://override.example/api");
    expect(n.apiUrlFor("mainnet")).not.toBe("https://override.example/api");
    expect(n.apiUrlFor("mainnet")).not.toBe(n.apiUrlFor("testnet"));
  });

  it("a local build stays on localhost", async () => {
    const n = await load({ NEXT_PUBLIC_NETWORK: "local" });
    expect([...n.SELECTABLE_NETWORKS]).toEqual(["local"]);
    expect(n.setNetwork("mainnet")).toBe(false);
    expect(n.CHAIN_ID).toBe(31337);
  });
});
