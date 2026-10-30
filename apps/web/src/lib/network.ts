import { chainsByNetwork, getDeployment, type NetworkName } from "@aethrafi/sdk";
import { useSyncExternalStore } from "react";

function parseNetwork(v: string | undefined): NetworkName {
  return v === "testnet" || v === "mainnet" || v === "local" ? v : "local";
}

/** Network a visitor sees first, chosen at build time from NEXT_PUBLIC_NETWORK (local | testnet | mainnet). */
export const DEFAULT_NETWORK: NetworkName = parseNetwork(process.env.NEXT_PUBLIC_NETWORK);

const STORAGE_KEY = "aethra-network";

export const NETWORK_LABEL: Record<NetworkName, string> = {
  local: "Localhost",
  testnet: "Testnet",
  mainnet: "Mainnet",
};

/** Networks the toggle offers. A local build stays on localhost; every other build switches testnet <-> mainnet. */
export const SELECTABLE_NETWORKS: readonly NetworkName[] = DEFAULT_NETWORK === "local" ? ["local"] : ["testnet", "mainnet"];

/** True once the Aethra core contracts are in the SDK address file for that network. */
export function isDeployed(network: NetworkName): boolean {
  return getDeployment(network).hub !== null;
}

/** A network can be selected when it is offered and has a deployment (mainnet unlocks when its addresses are published). */
export function isSelectable(network: NetworkName): boolean {
  return SELECTABLE_NETWORKS.includes(network) && isDeployed(network);
}

// NEXT_PUBLIC_* values are inlined at build time, so every variable is referenced literally.
const API_URLS: Record<NetworkName, string> = {
  local: process.env.NEXT_PUBLIC_API_URL_LOCAL || "http://127.0.0.1:54321/functions/v1/api",
  testnet: process.env.NEXT_PUBLIC_API_URL_TESTNET || "https://zqbnyshzgxhkfxoyrogq.supabase.co/functions/v1/api",
  mainnet: process.env.NEXT_PUBLIC_API_URL_MAINNET || "https://nczunmovephgtyrmsgvt.supabase.co/functions/v1/api",
};

const RPC_URLS: Record<NetworkName, string | undefined> = {
  local: undefined,
  testnet: process.env.NEXT_PUBLIC_RPC_URL_TESTNET || undefined,
  mainnet: process.env.NEXT_PUBLIC_RPC_URL_MAINNET || undefined,
};

/** Indexer API base URL. NEXT_PUBLIC_API_URL (older single-network setting) still overrides the default network. */
export function apiUrlFor(network: NetworkName): string {
  const legacy = network === DEFAULT_NETWORK ? process.env.NEXT_PUBLIC_API_URL : undefined;
  return (legacy || API_URLS[network]).replace(/\/$/, "");
}

/** JSON-RPC endpoint. NEXT_PUBLIC_RPC_URL (older single-network setting) still overrides the default network. */
export function rpcUrlFor(network: NetworkName): string {
  const legacy = network === DEFAULT_NETWORK ? process.env.NEXT_PUBLIC_RPC_URL : undefined;
  return legacy || RPC_URLS[network] || chainsByNetwork[network].rpcUrls.default.http[0]!;
}

const EXPLORERS: Record<NetworkName, string | null> = {
  local: null,
  testnet: "https://explorer.testnet.chain.robinhood.com",
  mainnet: "https://robinhoodchain.blockscout.com",
};

// ------------------------------------------------------------------------------------------------
// Active network.
//
// The exports below are live bindings: `setNetwork` reassigns them and every importer sees the new value.
// Providers re-mounts the app tree (key = network) on a switch, so components re-read them on the next render.
// The server and the first client render always use DEFAULT_NETWORK; the saved choice is applied after hydration.
// ------------------------------------------------------------------------------------------------

export let NETWORK: NetworkName = DEFAULT_NETWORK;
export let CHAIN = chainsByNetwork[DEFAULT_NETWORK] as (typeof chainsByNetwork)[NetworkName];
export let CHAIN_ID: number = CHAIN.id;
export let DEPLOYMENT = getDeployment(DEFAULT_NETWORK);
export let API_URL: string = apiUrlFor(DEFAULT_NETWORK);
export let RPC_URL: string = rpcUrlFor(DEFAULT_NETWORK);

const listeners = new Set<() => void>();

function apply(network: NetworkName) {
  NETWORK = network;
  CHAIN = chainsByNetwork[network];
  CHAIN_ID = CHAIN.id;
  DEPLOYMENT = getDeployment(network);
  API_URL = apiUrlFor(network);
  RPC_URL = rpcUrlFor(network);
  listeners.forEach((l) => l());
}

/** Switch the active network and remember the choice. Returns false if that network is not selectable. */
export function setNetwork(network: NetworkName): boolean {
  if (!isSelectable(network)) return false;
  if (network !== NETWORK) apply(network);
  try {
    window.localStorage.setItem(STORAGE_KEY, network);
  } catch {
    /* storage blocked: the choice just lasts for this visit */
  }
  return true;
}

/** Apply the saved choice, if any. Call once on the client after hydration. */
export function restoreNetwork(): void {
  let saved: string | null = null;
  try {
    saved = window.localStorage.getItem(STORAGE_KEY);
  } catch {
    return;
  }
  const network = parseNetwork(saved ?? undefined);
  if (saved && network !== NETWORK && isSelectable(network)) apply(network);
}

const subscribe = (l: () => void) => {
  listeners.add(l);
  return () => void listeners.delete(l);
};

/** Reactive active network (re-renders on a switch). Server and hydration render use DEFAULT_NETWORK. */
export function useNetwork(): NetworkName {
  return useSyncExternalStore(subscribe, () => NETWORK, () => DEFAULT_NETWORK);
}

export function explorerBase(network: NetworkName = NETWORK): string | null {
  return EXPLORERS[network];
}

export function explorerAddress(address: string, network: NetworkName = NETWORK): string | null {
  const base = explorerBase(network);
  return base ? `${base}/address/${address}` : null;
}

export function explorerTx(hash: string, network: NetworkName = NETWORK): string | null {
  const base = explorerBase(network);
  return base ? `${base}/tx/${hash}` : null;
}

export { type NetworkName };
