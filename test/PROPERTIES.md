# Additional Foundry coverage

The added tests reuse the accepted implementation and its local protocol mocks. They
need no network, fork, environment variables, installation, or files in `test/scratch`.
The original tests remain unchanged.

| Suite | Properties |
| --- | --- |
| `LoopInvariant.t.sol` | Three owners, multiple isolated accounts, arbitrary minor-unit deposits, added collateral, partial/full repayments, bounded interest accrual, receipt transfers (including approved operators), donations, recovery, close, and creation of replacement accounts. Input-based ghost ledgers track both debts, both collateral balances, historical contributions, receipt ownership and terminal state. Custody must equal aggregate collateral; every flash loan must preserve lender principal; protocol allowances must be cleared. |
| `AdapterInvariant.t.sol` | Three payers/recipients, direct Curve swaps, both Curve/V3 combinations, pure V3, exact input/output, approximate inverse quotes, rejected swaps, and donated dust. Independent wallet ledgers account for spending, exact recipient output, payer refunds and Curve rounding surplus. Donations remain isolated and protocol allowances return to zero. |
| `LaunchTokenProperties.t.sol` | Random transfers, approvals, allowance spending and rejected operations. Balances and allowances match independent ledgers, and aggregate balances always equal the immutable `10^27` supply. Unit tests pin zero, one, full supply, unlimited approval and allowance rollback. |
| `LoopFailurePaths.t.sol` | Invalid scalars, zero minimums, deadlines, malformed routes, absent approvals, signed conversion overflow, dust repayments, unexpected manager IDs, callback tampering, residual debt, stale-oracle exit, rejected safe receipt transfers, burn permissions and constructor checks. State snapshots verify failed operations roll back custody and accounting. |
| `AdapterFailurePaths.t.sol` | Bad routes, zero limits, unsupported exact-output direction, invalid recipients, ETH, expiry, taxed inputs, missing dependencies, lying routers, slippage and reentrancy. Reverts must restore payer, adapter and protocol balances and approvals. |
| `OracleProperties.t.sol` | Component freshness at the exact deadline and one second beyond, invalid rounds/answers/timestamps, decimals and code checks, rational rounding bounds, monotonicity, oldest-component timestamp, full-precision multiplication and signed result boundaries. |

Each invariant campaign explicitly targets only its handler's action selectors, runs
256 sequences of 64 calls, and fails on unexpected reverts. Expected failures check
their revert data. Deterministic sequence tests exercise all swap routes and a combined
position lifecycle; the position campaign also closes every remaining account and
recovers idle assets in `afterInvariant`.

The position value property applies to the fixture's fixed prices and zero-fee market,
with explicitly tracked interest. User wallets plus idle assets plus locked collateral,
less both debts, cannot gain value through operations. Rounding loss is bounded by one
WBTC minor unit per deposit and one per exit. These are model-specific guarantees,
not claims about production prices, fees, liquidations or withdrawal liquidity. The
existing example/fuzz tests separately cover fees, price losses and liquidation cleanup.
The adapter's value bound includes Curve fees and all tracked donations.

The oracle fuzz property runs 1,000 cases. All run settings are inline in the test
sources. No configuration or implementation changes are required.

Run `forge build` and `forge test`. To keep generated artifacts inside disposable
scratch space, use `--out test/scratch/out --cache-path test/scratch/cache` with either
command. `--offline` verifies against the already available compiler and vendored
dependencies.
