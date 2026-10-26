# Deferred deployments

Launchpad, credit (lending vault + credit manager) and buyback & burn are built and tested but hidden for now.
`script/Deploy.s.sol` and the deploy shell scripts do not deploy them.

When they ship, run after `Deploy` (and `SetupMarkets` on local/testnet):

- `script/deferred/DeployLaunchpadBuyback.s.sol` deploys launchpad, AETH and buyback, registers the launchpad and sets the hub fee config (buyback + 20% protocol share).
- `script/deferred/DeployCredit.s.sol` deploys the lending vault and credit manager.

Then set `NEXT_PUBLIC_FEATURES=launchpad,credit,buyback` for the web app and restore the addresses from `hidden` in `packages/sdk/src/addresses/<network>.json`.
