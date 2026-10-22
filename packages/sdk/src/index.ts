import type { Address } from "viem";
import local from "./addresses/local.json" with { type: "json" };
import testnet from "./addresses/testnet.json" with { type: "json" };
import mainnet from "./addresses/mainnet.json" with { type: "json" };
import type { NetworkName } from "./chains.js";

export * from "./chains.js";
export * from "./types.js";

export interface TokenInfo {
  address: Address;
  symbol: string;
  name: string;
  decimals: number;
  /** canonical | stock | launch | rwa | test */
  kind: string;
  logo?: string;
}

export interface Deployment {
  deployer: Address;
  poolManager: Address;
  weth: Address;
  multicall3: Address;
  permit2: Address;
  hub: Address | null;
  hook: Address | null;
  router: Address | null;
  positions: Address | null;
  dlmmFactory: Address | null;
  dlmmLimitOrders: Address | null;
  dammFactory: Address | null;
  launchpad: Address | null;
  lendingVault: Address | null;
  creditManager: Address | null;
  buyback: Address | null;
  aeth: Address | null;
  tokens: Record<string, TokenInfo>;
  oracles: Record<string, Address>;
  startBlock: number;
}

export const deployments: Record<NetworkName, Deployment> = {
  local: local as Deployment,
  testnet: testnet as Deployment,
  mainnet: mainnet as Deployment,
};

export function getDeployment(network: NetworkName): Deployment {
  return deployments[network];
}

export const DEPLOYER_ADDRESS: Address = "0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C";
