import { connectorsForWallets, type Wallet, type WalletList } from "@rainbow-me/rainbowkit";
import {
  coinbaseWallet,
  injectedWallet,
  metaMaskWallet,
  rabbyWallet,
  rainbowWallet,
  walletConnectWallet,
} from "@rainbow-me/rainbowkit/wallets";
import type { Chain } from "viem";
import { createConfig, createConnector, http } from "wagmi";
import { metaMask } from "wagmi/connectors";
import { CHAIN, RPC_URL } from "./network";

export const WALLETCONNECT_PROJECT_ID = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? "";
export const HAS_WALLETCONNECT = WALLETCONNECT_PROJECT_ID.trim().length > 0;

const APP = {
  appName: "Aethra Fi",
  appDescription: "Liquidity layer on Robinhood Chain",
  appUrl: "https://aethra-fi-testnet.vercel.app",
};

/** MetaMask via the MetaMask SDK connector, so it works without a WalletConnect project id. */
const metaMaskSdkWallet = (): Wallet => {
  // reuse RainbowKit's bundled MetaMask artwork; its WalletConnect path is never used here
  const rk = metaMaskWallet({ projectId: "unused" });
  return {
  id: "metaMask",
  name: "MetaMask",
  iconUrl: rk.iconUrl,
  iconBackground: rk.iconBackground,
  installed: typeof window !== "undefined" && Boolean((window as { ethereum?: { isMetaMask?: boolean } }).ethereum?.isMetaMask),
  downloadUrls: { browserExtension: "https://metamask.io/download" },
  createConnector: (walletDetails) =>
    createConnector((config) => ({
      ...metaMask({ dappMetadata: { name: APP.appName, url: APP.appUrl } })(config),
      ...walletDetails,
    })),
  };
};

function walletList(): WalletList {
  if (HAS_WALLETCONNECT) {
    return [
      { groupName: "Recommended", wallets: [metaMaskWallet, rabbyWallet, coinbaseWallet, rainbowWallet] },
      { groupName: "Other", wallets: [walletConnectWallet, injectedWallet] },
    ];
  }
  // No WalletConnect project id: injected / MetaMask SDK / Coinbase only, so builds never need a secret.
  return [{ groupName: "Available", wallets: [injectedWallet, metaMaskSdkWallet, coinbaseWallet] }];
}

let config: ReturnType<typeof makeConfig> | null = null;

function makeConfig() {
  const connectors = connectorsForWallets(walletList(), {
    ...APP,
    // only read by WalletConnect-based wallets, which are excluded when no id is configured
    projectId: HAS_WALLETCONNECT ? WALLETCONNECT_PROJECT_ID : "unused",
  });
  // widen the network-specific chain literal so the transports map type-checks for any build network
  const chain: Chain = CHAIN;
  return createConfig({
    chains: [chain],
    connectors,
    transports: { [chain.id]: http(RPC_URL, { batch: true }) },
    ssr: true,
  });
}

export function getWagmiConfig() {
  config ??= makeConfig();
  return config;
}
