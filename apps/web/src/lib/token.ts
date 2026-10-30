import type { Address } from "viem";

/**
 * The AETH token shown in the landing hero. It lives on Robinhood Chain mainnet whatever network the visitor
 * picks in the header. `address` stays null until the token launches; the hero block appears once it is set.
 */
export const AETH_TOKEN: { symbol: string; address: Address | null; explorer: string } = {
  symbol: "AETHRA",
  address: "0xE56B23204a66b43b8D788c6CD19749e5D5752C64",
  explorer: "https://robinhoodchain.blockscout.com",
};
