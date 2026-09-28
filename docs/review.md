# Verification and review boundary

Source provenance and inherited changes are listed in [PROVENANCE.md](../PROVENANCE.md). The historical live reads and prior review described by the upstream job are not new verification or independent approval of this copy.

The supplied protected files were read without modification. Their floor covers launch supply, constructor execution, application size and prohibited runtime opcodes. The delivered `DeploymentTest` rehearses that sequence with a fresh CREATE2 factory and absent external protocols, without environment variables, RPC, FFI or filesystem cheatcodes. It also checks that missing integrations cannot be used. Constructors require no initialization, privileged factory calls, or launch-token movement.

## Regression evidence

`testReportedFxusdShortfallNeedsRoundingBridge` uses the failure report's exact debt (`2368693941673936653513`) and rounded OHM sale proceeds (`2368693941660000000000`). An exit funded only for Cooler repayment fails by `13936653513` minor units before f(x) collateral is released. The test checks atomic rollback, then bridges the shortfall, repays both loans completely, returns the remaining capital, burns the receipt and checks the lender's unchanged balance. The browser uses the corresponding tested funding calculation.

`testFuzzDepositThenCloseWithFractionalQuotes` varies capital in WBTC minor units, BTC/USD prices and fractional OHM prices. It verifies final entry LTV, exact repayment, empty positions and allowances, unchanged lender funds and at most two WBTC minor units of round-trip rounding loss in the fee-free mock market. This bound describes that model only; production fees, interest and market moves increase losses. Existing repeated-deposit fuzzing also remains.

The transaction-lock regression explicitly enforces one f(x) operation per transaction and marks later user actions with a test-only transaction boundary. No production contract can clear that lock. Callback tests cover identity, altered parameters, funding, skipped/repeated callbacks and owner-authorized reentrancy. Other tests cover per-owner receipt rights, multi-user isolation, malformed routes, slippage rollback, debt-token migration, tax tokens, runtime dependency changes, stale prices, repayment budget enforcement, liquidation cleanup and adapter refunds.

Browser tests execute the shipped script with mocked wallet transport. They check that editing a receipt ID cannot transfer a different position from the displayed account, and that failed loads cannot retain old management permissions. Pure quote tests cover route reversal, top-up math and fractional exit financing. All browser libraries are vendored.

## Check commands

```sh
forge build
forge test
forge fmt --check
forge test --fuzz-runs 1000
forge test --isolate
node --check web/app.js
node --test web/*.test.cjs
sha256sum --check DEPENDENCIES.sha256
```

Compiler: Solidity 0.8.26; optimizer 200; via IR; Cancun; no metadata bytecode hash. Tests neither read nor modify process environment. Dependencies are ordinary committed source/distribution files, not network installs or submodules.

## Remaining limits

No production fork round trip, live deployment, funded-wallet operation, or independent adversarial review was performed here. Local mocks simplify f(x) share indexes, liquidations, redemption, fees and Cooler accrual. They demonstrate application behavior but cannot establish current liquidity, governance settings, protocol whitelist eligibility or every upstream accounting rule. A separate contributor must review these changes and the final manifest before release. The operator must rehearse entry and exit on the intended chain and verify every immutable integration address. See [deployment.md](deployment.md) for parameters, historical addresses and operational responsibilities.

Contracts remain exposed to external protocol governance, pauses, upgrades, liquidation and token behavior. They do not promise profit or a perpetual 33% LTV. Users monitor both loans and fund interest/losses. The launch token has no claim on strategy capital; only the receipt owns the isolated position.

## Results for this copy

Checked with Foundry 1.8.3 and Solidity 0.8.26:

- `forge build --sizes`: passed; all application runtimes are below 24,576 bytes. The largest is `LoopAccountDeployer` at 24,305 bytes, leaving 271 bytes; recheck this bound after any account change.
- `forge test`: 67 passed, zero failures or skips.
- `forge test --fuzz-runs 1000`: 67 passed; each of the three fuzz properties completed 1,000 runs.
- `forge test --isolate`: 67 passed, zero failures or skips.
- `forge fmt --check`: passed.
- `node --check web/app.js` and `node --test web/*.test.cjs`: passed; 11 browser/quote tests.
- `sha256sum --check DEPENDENCIES.sha256`: all 56 delivered dependency files matched after repairing inherited stale hashes.
- Browser ABIs regenerated from the compiled artifacts, including `LoopConfig.validate()`.

Compiler/linter warnings remain for timestamp checks, guarded external calls, bounded casts and simplified mock transfers. The account lock and balance-delta checks are exercised by the tests. These local results carry no independent release-approval authority.
