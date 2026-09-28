# Bitcoin Cooler

This is a copy of the project published for the requested [IdentityMD job](https://explorer.imd.fun/jobs/9df471c0-b9f9-474e-b2e1-1aa86c7f7412), with local launch-compatibility repairs and fractional-amount regression tests. Source commit and changes are recorded in [PROVENANCE.md](PROVENANCE.md). The launch manifest is a separate downstream artifact.

An immutable, noncustodial coordinator for the WBTC → f(x) fxMINT → OHM → gOHM → Cooler → WBTC loop, with isolated accounts, transferable position receipts, full exits, and a static management website.

This repository implements the protocol calls, rather than leaving production adapters as interfaces. It includes the Curve fxUSD/USDC bridge, Uniswap V3 routing, Olympus staking and MonoCooler calls, f(x) PoolManager operations, Morpho Blue flash liquidity for entry and repayment, and a composite Chainlink WBTC/USD feed. Deployment still requires the reviewed external contracts and liquid markets described in [deployment.md](docs/deployment.md). No transaction has been broadcast.

## Economics and limits

**A 50% initial loan does not automatically produce 33% final LTV.** If initial WBTC collateral is worth `C`, fx debt is `D = 0.5 C`, and Cooler credit buys WBTC worth `B`, final f(x) LTV is `D / (C + B)`. Even `B = 0.5 C` gives 33⅓%, before fees. Cooler values gOHM using its own origination ratio, which can be below its market price.

The implementation delivers the requested balances in one atomic transaction and explicitly quotes an additional **external WBTC top-up**, `T`, where necessary: `D / (C + B + T) <= 0.33`. It never silently borrows extra f(x) debt to fund that top-up. With no fees, `C = $100,000`, `D = $50,000`, `B = $31,250`, at least `$20,265.16` of extra WBTC is needed. The tests contribute `$21,000` and finish at approximately 32.84%. This is a mechanism example, not a return forecast.

Every deposit targets 50% borrowing on the **initial capital’s share of new credited collateral**, with a 49–50% permitted interval for fees, quote movement, and share rounding. Since all WBTC is supplied together, actual credited collateral after supply fees and rounding is allocated pro rata to initial capital; the top-up and reinvestment do not enlarge the initial borrowing budget. The website targets 49.95% of the conservative initial collateral quote. The final **whole position** must be at or below 33% under both the fresh composite feed and the f(x) pool's own debt-ratio view; otherwise the entire transaction reverts. Prices, funding charges, redemption/rebalancing, and accrued debt can change LTV after the transaction. There is no automatic keeper or permanent 33% guarantee. Cooler debt is additional leverage and is not included in the f(x) LTV number.

## Lifecycle

1. Call `LoopReceipt.createPosition()`. The wallet receives a standard ERC-721 receipt and a new full `LoopPosition` contract. The account is initially empty.
2. Approve the account for the exact input token and any separately quoted WBTC top-up. Call `deposit(DepositParams)` with routes, minimum outputs, debt amount, Cooler borrow amount, and deadline.
3. The account zaps input into WBTC and collects the top-up, then flash-borrows USDS equal to the requested Cooler loan from Morpho. It buys the reinvestment WBTC first and supplies all WBTC while borrowing fxUSD in **one** PoolManager operation. It buys OHM, stakes using `stake(account, amount, false, true)` to receive gOHM, deposits gOHM in MonoCooler, borrows USDS to repay Morpho, and verifies final LTV. The f(x) configuration locks for the whole transaction, so a second manager operation would revert. No privileged unlock is used. Repeat contributions and other f(x) operations must be separate transactions.

   Entry requires fee-free Morpho USDS liquidity of at least `coolerBorrow`. Missing flash funding, a short Cooler disbursement, slippage, or insufficient final collateral reverts the entire deposit. Idle USDS is preserved rather than spent to fund entry.
4. The receipt's current owner controls the account. Transferring it transfers **all assets and liabilities**, including idle tokens. Approved NFT operators can transfer the receipt but cannot directly operate the account. Receipt transfers are blocked during account operations.
5. `addCollateral`, `repayFx`, and `repayCooler` reduce risk without a fresh entry oracle. `recover` returns only idle ERC-20 balances; it cannot touch protocol collateral. Unused repayments stay recoverable.
6. `close(CloseParams)` fully unwinds. It flash-borrows USDS, repays current Cooler debt, withdraws gOHM, unstakes to OHM, sells OHM for USDS, buys the bounded fxUSD repayment budget, repays f(x) while withdrawing WBTC, and sells enough WBTC to repay Morpho. Remaining WBTC is returned or swapped to the chosen output token. Idle strategy tokens and swap surplus are also returned. Both collateral balances and debts must be zero before the receipt is burned. The minimum payout is checked against the **wallet's actual received balance**.

`flashAmount = 0` supports an exit funded by the owner's USDS instead of flash liquidity. A USDS contribution can cover a loss, interest, or insufficient flash liquidity. No profitable exit is guaranteed. Positions already in f(x) liquidation mode may need a separate partial `repayFx` before withdrawing, due to upstream validation order. If both protocols have fully liquidated the position, an explicit zero-output close burns the empty receipt. Accidental tokens received after closure remain recoverable by the final owner.

Exits are full-position exits, not fractional share redemptions. Use multiple receipts to manage independently redeemable tranches. `contributedWbtc` records historical external contributions; it is not NAV. The separate fixed-supply `LaunchToken` is **not** the strategy receipt and grants no right to capital.

## Immutability and responsibilities

Application contracts have no owner/admin roles, upgrade entry points, pause switches, fee setters, delegatecalls, sweep authority for third parties, or mutable dependencies. Constructors are nonpayable and accept only static address/uint arguments. Full accounts are created with `new`, not proxies or clones. There is no application fee.

External protocols retain their own governance, proxy, oracle, pause, redemption, and liquidation powers. Fixed dependency addresses do not make those protocols immutable. Monitor both loans and pay Cooler interest; no keeper does this for users. If Cooler governance changes the debt token, new loops are disabled. Repay that new debt token **directly to MonoCooler on behalf of the account**; after the debt is zero, this implementation permits withdrawing gOHM and finishing the exit. This recovery is tested. Changes to downstream ABI or withdrawal rules can still block exits.

“Any token” means a standard non-rebasing ERC-20 with an executable route and sufficient liquidity. Input transfer taxes are rejected by balance measurement. Tokens with transfer fees, malicious balances, rebases, blocklists, or unusual approvals are not guaranteed supported. Native ETH is not accepted; wrap it first. Intermediate assets must be the configured WBTC (8 decimals), fxUSD (18), OHM (9), gOHM (18), USDS (18), and USDC (6) for the Curve adapter. No arbitrary router target or call payload can be supplied.

## Build and check offline

Solidity **0.8.26** is pinned in `foundry.toml`; Foundry must have that compiler installed before an offline run. All Solidity and browser library sources are ordinary vendored files; no npm install, submodule, FFI, RPC, environment variables, or filesystem cheatcodes are used by the tests.

```sh
forge build
forge test
forge fmt --check
forge test --fuzz-runs 1000
node --check web/app.js
node --test web/*.test.cjs
```

The tests include an empty-chain CREATE2 launch rehearsal and the exact reported 13,936,653,513-wei fxUSD shortfall, plus complete entry/exit, repeat deposits, multi-user isolation, conservation, fee and interest changes, receipt rights, slippage rollback, initial/final LTV, oracle failures, owner-authorized reentrancy, malicious flash callbacks, tax tokens, debt migration, risk reduction, liquidation cleanup, adapter routes, approximate Curve inverse quotes, and runtime constraints. They use ABI-faithful local mocks with simplified economic models; they do not prove every upstream invariant or constitute a production fork rehearsal or independent security audit. See [review.md](docs/review.md).

## Website

```sh
python3 scripts/export_web_abi.py   # after changing Solidity and running forge build
python3 -m http.server 8080 --directory web
```

Open `http://localhost:8080`. The site needs no build step, backend, CDN, analytics, or hosted quote service. Connect a wallet, enter the reviewed receipt deployment and expected chain ID, then create/load a receipt. Deployment loading calls `LoopConfig.validate()` and rejects missing or incompatible integrations. The quote contract defaults to the configured `FxSwapRouter`, which combines Curve and V3 quotes. On a plain V3 test deployment, enter its V1 quoter explicitly. Routes can be edited for available liquidity. Exact-output reversal is handled automatically. The website verifies the connected chain and account, uses bounded approvals, displays both loans, top-ups, minimum returns, and deadlines, and simulates after approvals before submitting. It supports repeat deposits, full exits, risk reduction, receipt transfer, and idle-balance recovery. Editing the receipt ID clears the displayed position and disables management until the new position is loaded; transfer uses the loaded ID.

Application constructors store fixed external addresses without querying them, so the factory can deploy on an empty chain. Before any deposit, the config checks dependency code, token decimals, protocol bindings and LTV limits; the router validates its Curve bindings on every quote/swap, and the feed validates decimals and freshness on every read. A successfully deployed application still needs live, compatible dependencies to operate.

No production deployment is preconfigured. The chain-1 route suggestions were read-only quoted at one recorded block and must be re-quoted. A stale feed or missing liquidity may prevent entry while repayment and recovery controls remain useful. The website does not currently automate repayment in a migrated Cooler debt token; use the documented MonoCooler recovery call for that exceptional case.

Dependencies and licenses: [DEPENDENCIES.md](DEPENDENCIES.md).
