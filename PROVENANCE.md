# Source and local changes

The user requested a copy of [IdentityMD job 9df471c0-b9f9-474e-b2e1-1aa86c7f7412](https://explorer.imd.fun/jobs/9df471c0-b9f9-474e-b2e1-1aa86c7f7412).
Its published source is [identity-md-launches/launch-409-pleasr-build-contract-lets, commit 8a9eb533796fbd0b75bc133e3f3bea2474a1357b](https://github.com/identity-md-launches/launch-409-pleasr-build-contract-lets/tree/8a9eb533796fbd0b75bc133e3f3bea2474a1357b).

Contracts, vendored dependencies, website, and baseline tests were copied as ordinary files from that exact commit. No submodule or runtime download is required. Dependency license notices are retained. The publication carried stale hashes for 13 formatted Solidity library files; Solidity token equivalence was verified against the official pinned release archives, and `DEPENDENCIES.sha256` now records the delivered files. The published `launch.json` was excluded: the assignment's downstream manifest step selects deployment parameters.

Local changes:

- External integrations are validated at use time instead of queried in application constructors. This repairs the published project's empty-chain constructor failure while preserving fail-closed deposits, quotes, and oracle reads.
- Added a complete CREATE2 launch rehearsal, runtime opcode/size checks, and runtime validation failure tests.
- Added the reported fractional fxUSD shortfall as a concrete negative/positive regression, plus fuzzed round trips with arbitrary WBTC minor units, Bitcoin prices, and OHM prices. Repayment remains exact; no debt tolerance was added.
- Extracted browser exit-funding arithmetic into a tested helper and verified that the same shortfall is included in flash financing. Website deployment loading now validates protocol bindings.
- Updated documentation to distinguish inherited research and review from checks actually performed here.

The original source already contains the one-operation f(x) entry fix, exact-output repayment routing, and receipt-selection UI fix. Those are retained, with their regression tests. The rejected attempt described in the assignment is not available; its numeric failure is reproduced against this copy's local protocol model rather than claiming to have recovered that attempt's implementation.
