# Agent Credit Line

Owner-funded USDC credit lines for AI agents. The owner posts USDC into a vault, and each agent address gets a **max borrow**, a **borrow expiry**, a **repay-by due date**, and an optional **destination allowlist**. Agents **borrow** and anyone may **repay**. The owner can **pause** everything or **revoke** one agent instantly. Each line keeps a public repayment and default record. v1 has **no interest**; the owner may set an optional **flat fee** in basis points on each borrow.

> Prototype, **not audited**. It targets **Ethereum mainnet (1)** and **Base (8453)**, plus local anvil (31337) for development. The deploy scripts refuse any other chain and **refuse to broadcast on 1/8453 unless `CONFIRM_MAINNET=yes`**. Nothing has been deployed.

See [SPEC.md](SPEC.md) for the problem, competitors and choices, and [DEPLOY.md](DEPLOY.md) for the deploy runbook.

## Layout
| Path | What |
|---|---|
| `src/AgentCreditVault.sol` | The vault: lines, fee, allowlist, borrow, repay, pause, revoke, default record |
| `src/AgentCreditVaultFactory.sol` | Deploys one vault per owner, pinned to the factory's USDC (`vaultsOf`) |
| `src/MockUSDC.sol` | 6-decimal test token, used locally only |
| `test/` | Unit, fuzz and invariant tests (Foundry) |
| `test/fork/` | Fork tests against the real Circle USDC, plus a fork test of `Deploy.s.sol` |
| `script/Deploy.s.sol`, `script/DeployConfig.sol` | Deploy script and per-chain config (USDC addresses, live-chain flag) |
| `script/deploy.sh`, `script/verify.sh`, `script/deploy-anvil.sh` | Dry-run/broadcast wrapper, Etherscan v2 verify, local deploy |
| `script/dry-run-fork.sh`, `script/write-web-config.sh` | Anvil-fork dry run (port 8621) and dapp-config writer |
| `web/` | Vite + React + wagmi/viem dapp (Ethereum, Base and anvil) |
| `web/src/deployments.json` | Per-chain factory/USDC addresses written by a successful deploy |

## Contract model
- `openLine(agent, maxBorrow, expiry, dueDate, allowlistEnabled)` is owner only. `dueDate` must be at or after `expiry`. `setRecipient(agent, to, bool)` sets the optional allowlist.
- `borrow(to, amount, memo)` is called by the agent. It checks the line is active, not expired, not past due, not defaulted, the vault isn't paused, the allowlist (if enabled), the credit cap, and available liquidity. A flat fee (`feeBps`, default 0) is added to debt. State is updated before the transfer; the call is `nonReentrant`.
- `repay(agent, amount)` may be called by anyone, including while paused, after revoke, and after default. Overpayments are capped to the debt. Fees are repaid first.
- `markDefault(agent)` may be called by anyone after `dueDate` if debt remains. Default is sticky and blocks new borrows until the owner calls `clearDefault` after a full repayment. Lifetime totals stay on-chain.
- `revokeAgent(agent)` can be called by the owner or guardian. It bumps the line's epoch so the old allowlist dies; outstanding debt remains.
- `pause()` can be called by the owner or guardian, and `unpause()` by the owner only. `withdraw()` is owner only, works while paused, and takes unused USDC sitting in the vault (including repaid fees).
- Ownership uses `Ownable2Step`, so a Safe can be the owner.

## Run the dapp

```bash
cd web
npm install
# optional: cp .env.example .env   # only to override RPCs or factory addresses
npm run dev      # http://localhost:5173
npm run build    # production build
```

The dapp is Vite + React + wagmi/viem, on Ethereum mainnet and Base (and local anvil). Contract addresses come from `web/src/deployments.json`, with optional `VITE_FACTORY_*` / `VITE_USDC_*` overrides in `web/.env`. When the factory address for the selected chain is empty, the page shows a clear **Not deployed yet** state and disables create-vault.

Connect a wallet, switch network, then: create or pick a vault, deposit USDC, open a line (cap, expiry, due date, optional allowlist, fee), borrow or repay, inspect the public record and recent events, pause, revoke, or mark/clear a default.

## Tests

Needs Foundry (`forge` / `anvil`; this repo expects `~/.foundry/bin` on `PATH`) and Node 20+.

```bash
forge build
forge test              # unit, fuzz, invariant, and anvil deploy-script tests; fork tests skip without a fork
make dry-run-mainnet    # Deploy.s.sol dry-run + CONFIRM_MAINNET guard, on an anvil mainnet fork at port 8621
```

Fork tests (real Circle USDC, plus the deploy-script fork tests). This repo uses **port 8621 only**:

```bash
anvil --port 8621 --fork-url https://ethereum-rpc.publicnode.com   # Ethereum fork
make test-fork-mainnet
# Base, using Foundry's own fork (no extra anvil):
make test-fork-base
```

## Deploy to Ethereum or Base (not done: needs Lef's wallet and OK)

| Chain | Id | USDC (checked on fork: symbol USDC, 6 decimals) |
|---|---|---|
| Ethereum mainnet | 1 | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Base | 8453 | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

Once the wallet is set (Foundry keystore account, keystore file, or `DEPLOYER_KEY` in a git-ignored `.env`):

```bash
cp .env.example .env && set -a && source .env && set +a
make dry-run-mainnet                 # local anvil fork on port 8621; sends nothing
CONFIRM_MAINNET=yes make deploy-mainnet
CONFIRM_MAINNET=yes make deploy-base
```

A successful broadcast writes the factory address into `web/src/deployments.json` and, if `ETHERSCAN_API_KEY` is set, verifies via the Etherscan v2 API. See [DEPLOY.md](DEPLOY.md) for signer options and `./script/verify.sh`.

- `deploy.sh` and `Deploy.s.sol` both print the chain. Each refuses to broadcast on 1 or 8453 without `CONFIRM_MAINNET=yes`, so the guard holds even if someone calls `forge script` directly.
- Never commit `.env`, keys, or `broadcast/`.

## Local end-to-end (anvil, no keys)

```bash
anvil                                   # terminal 1 (chain 31337)
./script/deploy-anvil.sh                # factory and MockUSDC on a fresh anvil
cd web && npm install && npm run dev
```

The anvil deploy uses anvil's unlocked dev accounts, so no private key is stored anywhere.

## Regenerate ABIs
`forge build && node tools/gen-abi.mjs` writes `web/src/abi.ts`.
