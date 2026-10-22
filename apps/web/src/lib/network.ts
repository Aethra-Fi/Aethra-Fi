import { chainsByNetwork, getDeployment, type NetworkName } from "@aethra/sdk";

function parseNetwork(v: string | undefined): NetworkName {
  return v === "testnet" || v === "mainnet" || v === "local" ? v : "local";
}

/** Active network, chosen at build time from NEXT_PUBLIC_NETWORK (local | testnet | mainnet). */
export const NETWORK: NetworkName = parseNetwork(process.env.NEXT_PUBLIC_NETWORK);
export const CHAIN = chainsByNetwork[NETWORK];
export const CHAIN_ID = CHAIN.id;
export const DEPLOYMENT = getDeployment(NETWORK);
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL || CHAIN.rpcUrls.default.http[0]!;

export const NETWORK_LABEL: Record<NetworkName, string> = {
  local: "Localhost",
  testnet: "Testnet",
  mainnet: "Mainnet",
};

const EXPLORERS: Record<NetworkName, string | null> = {
  local: null,
  testnet: "https://explorer.testnet.chain.robinhood.com",
  mainnet: "https://robinhoodchain.blockscout.com",
};

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
