# Deployment parameters and operator runbook

Deploy only after external independent adversarial review and a fork rehearsal against the intended block. The contributor task does not authorize broadcasting or wallet-key access. There is no deploy script that reads secrets or broadcasts. The manifest/deployment coordinator supplies constructor arguments to the exact built artifacts.

## Artifact order

| Artifact | Constructor arguments | Purpose |
|---|---|---|
| `LaunchToken` | none | Exactly 1e27 minor units to its deployer; 18 decimals; no later mint/admin |
| `WbtcUsdFeed` | `wbtcBtc`, `btcUsd`, `wbtcMaxAge`, `btcMaxAge` | Independent feed validation; 8-decimal WBTC/USD product |
| `FxSwapRouter` | `v3Router`, `v3Quoter`, `curve`, `fxUSD`, `usdc` | Fixed protocol routing and on-chain quote composition |
| `LoopConfig` | `wbtc`, `fxUSD`, `ohm`, `gohm`, `usds`, `manager`, `pool`, `cooler`, `staking`, `router`, `morpho`, `priceFeed`, `maxPriceAge` | Set `router` and `priceFeed` to the preceding application deployments |
| `LoopAccountDeployer` | `config` | Full, immutable account creation code |
| `LoopReceipt` | `accountDeployer` | ERC-721 receipt and account creation entry point |

The five application artifacts plus the launch token fit the launch's application count limit. `LoopPosition` is created at runtime per user and must not be deployed as a shared account. No initializer, ownership setup, token transfer, or factory callback is required. The launch token supply remains entirely with its factory/deployer. External-dependency constructors validate nonzero/distinct addresses and age limits, but do not call external protocols or require their code at construction time. This permits the protected empty-chain factory deployment. The deployer and receipt only check their already-created application dependencies. No validation result is cached and no later initialization is needed.

Call `LoopConfig.validate()`, `FxSwapRouter.validate()`, and `WbtcUsdFeed.latestRoundData()` as deployment preflight before advertising deposits. `LoopPosition.deposit()` rechecks token decimals, deployed code, protocol bindings, WBTC scaling, and the f(x) LTV range before collecting funds. Router quotes/swaps recheck Curve bindings; each feed read checks component decimals and freshness. Missing or incompatible upstream dependencies fail closed. Constructor success alone does not establish a usable integration or source-code trust.

## Inherited Ethereum reference snapshot — not deployment authorization

The copied project records read-only observations at **Ethereum block 26,070,119**. Those observations were not repeated in this assignment; all addresses, liquidity and governance settings below are historical inputs requiring fresh verification before deployment. These are candidate constructor parameters, not addresses selected for a live launch. Sepolia does not gain these mainnet integrations by copying the addresses; use separately deployed mocks only for an explicitly labeled demo.

| Parameter | Reference address/value |
|---|---|
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |
| fxUSD | `0x085780639CC2cACd35E474e71f4d000e2405d8f6` |
| OHM | `0x64aa3364F17a4D01c6f1751Fd97C2BD3D7e7f1D5` |
| gOHM | `0x0ab87046fBb341D058F17CBC4c1133F25a20a52f` |
| USDS | `0xdC035D45d973E3EC169d2276DDab16f1e407384F` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| f(x) PoolManager | `0x250893CA4Ba5d05626C785e8da758026928FCD24` |
| WBTC long pool | `0xAB709e26Fa6B0A30c119D8c55B887DeD24952473` |
| MonoCooler | `0xdb591Ea2e5Db886dA872654D58f6cc584b68e7cC` |
| Olympus staking | `0xB63cac384247597756545b500253ff8E607a8020` |
| Uniswap V3 SwapRouter, original deadline-bearing ABI | `0xE592427A0AEce92De3Edee1F18E0157C05861564` |
| Uniswap V3 Quoter V1 | `0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6` |
| Curve StableSwap NG USDC/fxUSD | `0x5018be882dcce5e3f2f3b0913ae2096b9b3fb61f` |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
| Chainlink WBTC/BTC, 8 decimals | `0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23` |
| Chainlink BTC/USD, 8 decimals | `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c` |
| Suggested freshness bounds | WBTC/BTC 90,000 seconds; BTC/USD 7,200 seconds; LoopConfig 90,000 seconds |

The two feed heartbeats published at research time were 86,400 and 3,600 seconds. The suggested bounds allow delayed updates and are deployment decisions, not hard-coded contract policy. The composite reports the older component timestamp; the LoopConfig bound must accommodate it. Do not substitute BTC/USD alone and silently assume WBTC's peg. The Chainlink product checks nonzero positive answers, future/zero/stale timestamps, and answered rounds. The f(x) protocol price may use other data and must also pass the final LTV check.

At the recorded block, PoolManager's whitelist was zero, so dynamically created accounts could call it. If a whitelist is active at deployment or is introduced later, **each account** must be accepted; approving the receipt alone does not authorize them. WBTC pool min/max debt ratios were `1e14`/`855e15` (0.01%/85.5%). MonoCooler had USDS debt, 1,000 USDS minimum debt, and borrowing enabled. Olympus staking warmup was zero, necessary for atomic gOHM receipt. These settings are externally governed and must be rechecked.

## Transaction-wide f(x) lock and entry liquidity

The reviewed [PoolConfiguration lock](https://github.com/AladdinDAO/fx-protocol-contracts/blob/5e198e93657db008a57129e7eea21a996618f17f/contracts/core/PoolConfiguration.sol#L359-L378) remains set until the end of the transaction; explicit unlock requires a protocol role. Accounts do not have that role. Each deposit therefore flash-borrows `coolerBorrow` USDS from the configured Morpho, buys WBTC, and supplies initial capital, reinvestment, and the wallet top-up in a single `operate`. The resulting fxUSD funds OHM/gOHM collateral, and Cooler’s new USDS loan repays the flash loan. The entry callback is committed to the exact deposit parameters, capital, and oracle price; it verifies lender identity, funding, amount, single use, and the actual Cooler disbursement. Existing idle USDS is preserved.

Deployment rehearsal must verify Morpho’s fee-free USDS liquidity for the entry size as well as exit liquidity. There is no entry fallback without Morpho. Submit each deposit, collateral addition, f(x) repayment, or close in its own transaction. Batching f(x) manager operations (even across different accounts) can hit the shared configuration lock. The mocks expose an explicit test-only transaction boundary because one Foundry test otherwise contains multiple user actions; no production account calls unlock or resets this lock.

Using these repairs with an existing installation requires a new account deployer and receipt deployment. Existing immutable accounts cannot be patched. This task has not deployed any contracts.

## Routes and quote behavior

Route bytes use V3 packing: `address | uint24 fee | address | …`. Fee **0** is reserved for the immutable Curve bridge, only at an fxUSD endpoint adjoining configured USDC. All other hops are V3. At most ten hops are accepted. Exact-input routes are forward; exact-output routes reverse **both** token and fee order. The website accepts forward paths for all fields and performs reversal.

At the recorded block, the ordinary V3 fee tiers had no fxUSD pool against USDC, WETH, USDS, USDT, or DAI. Use the Curve leg. Candidate paths quoted successfully:

| Operation | Forward route |
|---|---|
| Buy OHM | fxUSD → **0** → USDC → **500** → WETH → **3000** → OHM |
| Buy reinvestment WBTC using entry flash USDS | USDS → **3000** → USDC → **500** → WBTC |
| Sell OHM at exit | OHM → **3000** → WETH → **500** → USDC → **3000** → USDS |
| Acquire fxUSD repayment | USDS → **3000** → USDC → **0** → fxUSD |
| Repay flash loan | WBTC → **500** → USDC → **3000** → USDS |

WETH is `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`. Observed pools: USDC/WETH 500 `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640`, OHM/WETH 3000 `0x88051B0eea095007D3bEf21aB287Be961f3d8598`, USDS/USDC 3000 `0xa66A2770bC0e0c65B63b5A3BB4560e90F95D6146`, WBTC/USDC 500 `0x9a772018FbD77fcD2d25657e5C547BAfF3Fd7D16`. Liquidity and quotes can change; neither address existence nor a historical quote guarantees execution.

Curve `get_dx` is only an approximate inverse with dynamic fees. At the recorded block, `get_dx(USDC,fxUSD,1_000_000e18)+1` was insufficient by about 0.29353 fxUSD. `FxSwapRouter` therefore validates the inverse against `get_dy`, finds a sufficient upper bound with up to 16 increasing steps, and refines it with at most 16 binary steps. Quote and execution use the same algorithm. Failure to find a sufficient bound reverts. Small excess fxUSD belongs to the caller. Generic exact-output swaps **from** fxUSD are deliberately unsupported; the strategy uses exact-input fxUSD sales and exact-output fxUSD purchases.

## Exit responsibilities and exceptional recovery

- The owner supplies route-specific minimum outputs, maximum spends, deadline, and any contribution. All callbacks and swap recipients are fixed by code. No keeper/third party may initiate an exit.
- Set the flash amount to cover Cooler repayment **plus** `max(0, maxUsdsForFx - minimumOhmSaleProceeds)`, minus available owner/idle USDS. Even at unchanged prices, 9-decimal OHM sale proceeds can round below 18-decimal fxUSD debt. Never round the debt down to match sale proceeds; bridge the difference before f(x) releases WBTC. The reported debt `2368693941673936653513` and sale proceeds `2368693941660000000000` need an additional `13936653513` minor units of USDS in the 1:1 mock market. Exact-output routing buys the full repayment budget and remains bounded by the owner’s spend limit. Morpho Blue requires enough USDS liquidity and currently uses a fee-free flash API. This implementation assumes that API/fee model; another lender is not interchangeable. The website buffers Cooler accrual by 2 bps within a ten-minute quote window and still simulates before submitting.
- f(x) repayment can burn fxUSD directly without allowance. The account measures actual spend and caps it at the explicit budget. Include protocol repayment fees and share rounding; unused funds are returned/recoverable.
- No withdrawal is promised when insolvent, swaps lack liquidity, protocols pause, or withdrawals are disallowed. Add USDS for an exit deficit or WBTC for collateral support. Owners can use direct repayment paths while the entry oracle is stale.
- For a Cooler debt-token migration: read `MonoCooler.debtToken()` and `accountPosition(account)`, approve that **new token** to MonoCooler, call `repay(uint128 amountInWad, account)` for the full current debt, then call this account's close. MonoCooler always expresses debt in 18-decimal WAD even if the migrated token does not use 18 decimals; approval uses the token's own units. Verify upstream conversion and round up appropriately. The old-USDS close only proceeds after new-token debt is zero.
- Some f(x) liquidation states disallow withdrawal even when repayment is included in the same operation. A prior, sufficient partial `repayFx` can restore eligibility; external liquidations/rebalancing may instead remove assets. No generic escape call is included.
- Hosted website operators must maintain accurate deployment addresses, preserve the shipped ABI, serve files over HTTPS, and test token routes. They have no contract administrative powers. Users must monitor both loans and understand that transferring the receipt transfers debt exposure too.

## Primary integration sources

- [f(x) fxMINT mechanism](https://fxprotocol.gitbook.io/fx-docs/f-x-protocol-mechanisms/fxmint-borrowing-fxusd-against-your-btc-and-eth), [PoolManager at reviewed source commit](https://github.com/AladdinDAO/fx-protocol-contracts/blob/5e198e93657db008a57129e7eea21a996618f17f/contracts/core/PoolManager.sol), [f(x) SDK deployment configuration](https://github.com/AladdinDAO/fx-sdk/blob/main/src/configs/contracts.ts).
- [Olympus MonoCooler interface at reviewed source commit](https://github.com/OlympusDAO/olympus-v3/blob/1032e2469c00a62b2bf83518506fbe858eeea621/src/policies/interfaces/cooler/IMonoCooler.sol), [Cooler documentation](https://docs.olympusdao.finance/main/overview/cooler-loans), [staking interface](https://docs.olympusdao.finance/main/contracts/docs/src/interfaces/IStaking.sol/interface.IStaking).
- [Curve StableSwap NG implementation](https://github.com/curvefi/stableswap-ng/blob/main/contracts/main/CurveStableSwapNG.vy), [Aladdin token/pool configuration](https://github.com/AladdinDAO/aladdin-v3-contracts/blob/main/scripts/utils/tokens.ts).
- [Uniswap V3 SwapRouter](https://github.com/Uniswap/v3-periphery/blob/main/contracts/SwapRouter.sol), [Morpho Blue flashLoan implementation](https://github.com/morpho-org/morpho-blue/blob/main/src/Morpho.sol), [Chainlink Ethereum feed directory](https://reference-data-directory.vercel.app/feeds-mainnet.json).

Live reads and source inspection complement local mocks but are not an end-to-end mainnet fork test. Deployment rehearsal must include actual pool fees/capacity, token scaling, oracle heartbeats, receipt account whitelist eligibility, warmup, liquidity, Morpho entry and exit funding, the transaction-wide manager lock, round-trip losses, depleted liquidity, and changed governance parameters.
