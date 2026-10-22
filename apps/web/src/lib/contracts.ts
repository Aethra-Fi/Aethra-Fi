import type { Address } from "viem";
import type { Deployment } from "@aethra/sdk";
import * as abis from "./abis";
import { DEPLOYMENT } from "./network";

/**
 * Single plug-in point for contract ABIs. Replace a value with the SDK export
 * (e.g. `import { aethraRouterAbi } from "@aethra/sdk"`) once the lead publishes full ABIs.
 */
export const ABIS = {
  router: abis.aethraRouterAbi,
  positions: abis.aethraPositionsAbi,
  dlmmFactory: abis.dlmmFactoryAbi,
  dlmmLimitOrders: abis.dlmmLimitOrdersAbi,
  dammFactory: abis.dammFactoryAbi,
  launchpad: abis.launchpadAbi,
  lendingVault: abis.lendingVaultAbi,
  creditManager: abis.creditManagerAbi,
  buyback: abis.buybackAbi,
  hub: abis.hubAbi,
  poolManager: abis.poolManagerAbi,
  // per-instance contracts (address comes from the pool / token)
  erc20: abis.erc20Abi,
  dlmmPool: abis.dlmmPoolAbi,
  dammPool: abis.dammPoolAbi,
} as const;

export type ContractName = keyof typeof ABIS;
export type DeployedContract = Exclude<
  {
    [K in keyof Deployment]: Deployment[K] extends Address | null ? K : never;
  }[keyof Deployment],
  "deployer"
>;

/** Proxy address of a protocol contract on the active network, or null when not deployed yet. */
export function addressOf(name: DeployedContract, deployment: Deployment = DEPLOYMENT): Address | null {
  const a = deployment[name] as Address | null | undefined;
  if (!a || /^0x0{40}$/i.test(a)) return null;
  return a;
}

/** `{ address, abi }` for wagmi hooks, or null when the contract is not deployed on this network. */
export function contract<N extends DeployedContract & ContractName>(name: N) {
  const address = addressOf(name);
  return address ? ({ address, abi: ABIS[name] } as const) : null;
}

export interface ContractEntry {
  key: DeployedContract | string;
  label: string;
  description: string;
  address: Address | null;
  external?: boolean;
}

export interface ContractGroup {
  category: string;
  entries: ContractEntry[];
}

/** Grouped contract list for the /contracts page. */
export function contractGroups(d: Deployment): ContractGroup[] {
  const e = (key: DeployedContract, label: string, description: string, external = false): ContractEntry => ({
    key,
    label,
    description,
    address: addressOf(key, d),
    external,
  });
  const groups: ContractGroup[] = [
    {
      category: "Core & config",
      entries: [e("hub", "AethraHub", "Asset, oracle and pool registry plus roles and protocol fee config.")],
    },
    {
      category: "v4 hooks & fees",
      entries: [e("hook", "AethraHook", "Combined dynamic-fee and oracle-guard hook for Uniswap v4 pools.")],
    },
    {
      category: "Smart router",
      entries: [e("router", "AethraRouter", "Exact-input multi-venue router across v4, DLMM, DAMM and launch curves.")],
    },
    {
      category: "Positions & locks",
      entries: [e("positions", "AethraPositions", "ERC-721 v4 LP positions with built-in locks and vesting.")],
    },
    {
      category: "Venues",
      entries: [
        e("dlmmFactory", "DLMM factory", "Deploys discrete-bin pools as beacon proxies."),
        e("dlmmLimitOrders", "DLMM limit orders", "Single-bin orders that fill as the active bin crosses them."),
        e("dammFactory", "DAMM factory", "Deploys dynamic single-range pools with optional launch fee schedules."),
      ],
    },
    {
      category: "Markets",
      entries: [e("launchpad", "Launchpad", "Bonding-curve launches that graduate into locked v4 liquidity.")],
    },
    {
      category: "Credit",
      entries: [
        e("lendingVault", "Lending vault", "ERC-4626 stablecoin vault lending to the credit manager."),
        e("creditManager", "Credit manager", "Borrow against pledged position NFTs."),
      ],
    },
    {
      category: "Buyback & burn",
      entries: [
        e("buyback", "Buyback", "Swaps protocol revenue into AETH and burns it."),
        e("aeth", "AETH", "Protocol token bought back and burned."),
      ],
    },
    {
      category: "External",
      entries: [
        e("poolManager", "Uniswap v4 PoolManager", "Canonical singleton reused by Aethra hook pools.", true),
        e("weth", "WETH", "Wrapped ether.", true),
        e("permit2", "Permit2", "Canonical token approval contract.", true),
        e("multicall3", "Multicall3", "Batched reads.", true),
      ],
    },
  ];
  const oracles = Object.entries(d.oracles ?? {});
  if (oracles.length) {
    groups.push({
      category: "Oracles",
      entries: oracles.map(([sym, address]) => ({ key: `oracle:${sym}`, label: `${sym} feed`, description: "Price feed", address })),
    });
  }
  const tokens = Object.values(d.tokens ?? {});
  if (tokens.length) {
    groups.push({
      category: "Tokens",
      entries: tokens.map((t) => ({ key: `token:${t.symbol}`, label: t.symbol, description: `${t.name} (${t.kind})`, address: t.address })),
    });
  }
  return groups;
}
