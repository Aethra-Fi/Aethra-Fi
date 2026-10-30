# @aethrafi/sdk

TypeScript SDK for [Aethra Fi](https://aethra.finance), the liquidity layer on Robinhood Chain. It ships the deployed contract addresses, contract ABIs, chain definitions for [viem](https://viem.sh), route quoting through the Aethra router, and price math for v4 ticks and DLMM bins.

## Install

```bash
npm install @aethrafi/sdk viem
```

`viem` is a peer dependency (v2).

## Networks

| Network | Chain ID | Name in the SDK |
| --- | --- | --- |
| Robinhood Chain | 4663 | `mainnet` |
| Robinhood Chain Testnet | 46630 | `testnet` |

## Read the deployment

```ts
import { createPublicClient, http } from "viem";
import { chainsByNetwork, getDeployment, aethraHubAbi } from "@aethrafi/sdk";

const chain = chainsByNetwork.mainnet;
const d = getDeployment("mainnet"); // proxy addresses: hub, hook, router, positions, ...
const client = createPublicClient({ chain, transport: http() });

const owner = await client.readContract({ address: d.hub!, abi: aethraHubAbi, functionName: "owner" });
```

Addresses are the proxy addresses; they stay the same across upgrades. A field is `null` when that contract is not deployed on the network.

## Quote a route

The router quotes any route of up to a few hops with `quote` over `eth_call`. Each hop names a venue (1 v4, 2 DLMM, 3 DAMM), the pool and venue data.

```ts
import { aethraRouterAbi, encodePoolKey, sortTokens } from "@aethrafi/sdk";

const [token0, token1] = sortTokens(d.weth, d.tokens.USDG.address);
const key = { currency0: token0, currency1: token1, fee: 0x800000, tickSpacing: 10, hooks: d.hook! };
const hops = [{ venue: 1, pool: "0x0000000000000000000000000000000000000000", tokenIn: d.weth, tokenOut: d.tokens.USDG.address, data: encodePoolKey(key) }];

const { result: [amountOut] } = await client.simulateContract({
  address: d.router!,
  abi: aethraRouterAbi,
  functionName: "quote",
  args: [hops, 10n ** 15n], // 0.001 WETH
});
```

`findBestRoute` and `quoteRoutes` search direct and two-hop routes over a list of pools. Use `minOut(amountOut, slippageBps)` for the swap's minimum output.

## Math helpers

`priceToSqrtPriceX96`, `sqrtPriceX96ToPrice`, `tickToPrice`, `priceToTick`, `nearestUsableTick`, `fullRangeTicks`, `binToPrice`, `priceToBin`, `binDistribution`, `formatFeePips`.

## REST API

Indexed pools, swaps, analytics and events are served by the Aethra API. See https://aethra.finance/developers.

## License

MIT
