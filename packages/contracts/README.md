# @aethra/contracts

Foundry project for Aethra Fi: the hub, the v4 hook, the router, positions, DLMM, DAMM, the launchpad, credit and buyback.

```bash
forge build
forge test
```

Every core contract is a UUPS (ERC-1967) proxy with ERC-7201 namespaced storage. DLMM and DAMM pools are BeaconProxies.
