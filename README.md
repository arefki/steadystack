# SteadyStack — Set-and-Forget DCA with a Deterministic Crash Guard

Entry for the **Reactive Omni Buildathon** (DoraHacks), **Set It and Forget It** track.
Deadline: Dec 5, 2026 20:00 UTC.

## What it is

A dollar-cost-averaging machine that lives entirely on-chain — no bot, no server:

- A **reactive contract on Lasna** watches the Uniswap V3 WETH/USDC pool on Base Sepolia
  (`Swap` events = price signal) plus `CRON100` ticks (the DCA schedule).
- On each due tick (price ≤ maxPrice, not paused, guard clear) it requests a **callback**
  to a **vault on Base Sepolia**, which swaps USDC → WETH directly against the pool.
- A **deterministic crash guard** pauses buying if the spot price drops more than the
  configured threshold vs the last buy price, and resumes when the EMA recovers above
  the resume threshold (real hysteresis — the EMA is anchored at the crash price on trip).

No off-chain component makes decisions. Every buy is a verifiable on-chain event chain:
Swap/CRON event → `react()` → callback request → `executeBuy` → `Bought`.

## Deployed (testnet — live and verified)

Both contracts live at the **same address** on their chains (same deployer nonce):

| Contract | Chain | Address |
|---|---|---|
| `SteadyReactive` | Reactive Lasna (5318007) | `0xdcF6cccD1d6eC0f071409f6e09989AE637CC501f` |
| `SteadyVault` | Base Sepolia (84532) | `0xdcF6cccD1d6eC0f071409f6e09989AE637CC501f` |

- **Sourcify: exact match (creation + runtime) for both contracts.**
- **8+ full-loop DCA buys executed on-chain** (1 USDC → ~0.0000376 WETH each).
  First buy — Lasna react tx `0x0d083ddbe4964a1e442aaa82d5f0d6caf8e49c395ea2ea334dbd6a7d47c59a4a`,
  callback tx `0x1fd4f31123e43ee4983cad6e987faa37c147e446c88447def374f416bf75ca94`
  (Base Sepolia block 60893168, 233,937 gas).
- **Guard trip + resume proven live**: a 0.0007 WETH sell tripped the guard
  (`guardTripped=true`, vault paused, buys blocked); five buy-back swaps recovered
  the EMA and the guard cleared on its own (vault unpaused, DCA resumed).
- Deploy txs: reactive `0xcca22aa6872e71299dc40e40b1f2cd298a2431be8ca3d48bb1bac1bab36e196c`
  (Lasna block 8741781), vault `0x8362bcd9f4f6226f8c133a00ad607c4f2c5863debedb3833381f99f43161958d`
  (Base Sepolia block 60892270).

## Design decisions (all verified, not assumed)

- **Direct pool swap, no router.** The address recorded in early docs as SwapRouter02
  is actually the NonfungiblePositionManager (verified on-chain: has `mint()`/`factory()`,
  no `exactInputSingle`); canonical SwapRouter02 and Universal Router have no code on
  Base Sepolia. The vault calls `pool.swap` + `uniswapV3SwapCallback` directly, with
  `minOut` enforced on the return values and an exact-input invariant check.
- **The pool rejects `sqrtPriceLimitX96 = 0`** (reverts `SPL`, verified in a fork test).
  The vault passes `MIN_SQRT_RATIO + 1` (4295128740) as the effectively-unlimited limit.
- **Price math is overflow-safe without FullMath**: `price6 = 10^18 * 2^192 / sqrtP²`
  computed in two steps (`a = 2^192 / sqrtP; result = a * 1e18 / sqrtP`, max
  intermediate 2^252) — verified against exact big-int ground truth in Python (≤1 ulp).
- **Vault-side pricing (slot0 only).** `minOut` is derived from a live `slot0()` read
  at execution time, and `executeBuy` re-checks the live price vs `maxPrice` — closing
  the guard/callback race. QuoterV2 was rejected: it can revert inside a callback.
- **Skip, don't revert.** Expected guard conditions (paused, price high, low balance,
  no price) emit `BuySkipped` and return instead of reverting, so one bad tick never
  stalls the loop with a failed callback.
- **Reference price updates only on confirmed fills** (vault `Bought` events), never
  optimistically — a skipped buy must not move the guard reference.
- **Owner break-glass**: `clearGuard()` (reactive) + `resumeGuard()` (vault) recover
  from a stuck guard or a lost cross-chain pause callback.

## Repo layout

- `src/` — `SteadyReactive.sol`, `SteadyVault.sol`, `PriceMath.sol`, plus the Phase 2
  `HelloReactive`/`HelloCallback` proof-of-concept
- `test/` — forge test suite (TDD), including a fork test that performs a real
  USDC→WETH swap on Base Sepolia
- `script/` — deploy, setup, fund, and guard-test scripts (testnet only)
- `lib/` — vendored dependencies (`forge-std`, `reactive-lib-omni`) so the repo
  builds with a plain `forge build` — no submodule init needed

## Build & test

```sh
forge build   # 0 warnings
forge test    # 97 tests, 0 failures (incl. the live fork swap)
```

## Deploy (testnet only, $0)

All deploys use a fresh testnet-only keypair (`.env`, gitignored — never a mainnet key).
Lasna gas is **100 gwei**; use `--legacy --gas-price 100000000000` (forge's EIP-1559
estimate doubles the fee and can exceed the balance). Deploy order: reactive (funded
with lREACT at deploy) → vault → fund the vault's callback reserves (`depositTo`,
BEFORE `setRecipient`) → fund the vault with USDC → `setRecipient` + `setRule`.

**Operational note (measured live):** a buy-react costs ~170k gas ≈ 0.017 lREACT, and
the loop burns roughly 0.5–0.8 lREACT/hour at one buy per ~2-min tick (buys + tick /
Swap reacts). Any outstanding debt suspends the reactive — monitor `debt()` and the
reactive balance, and call `coverDebt()` + top up before they run dry.

## Links

- Buildathon: https://dorahacks.io/hackathon/reactive-omni-buildathon/detail
- Reactive docs: https://dev.reactive.network/
- Lasna explorer: https://lasna.reactscan.net/
- Base Sepolia explorer: https://sepolia.basescan.org/
