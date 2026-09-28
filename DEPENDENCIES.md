# Vendored dependencies

All delivered libraries are ordinary files, with no submodules or package installation step.
File hashes of the delivered files are recorded in `DEPENDENCIES.sha256`. The copied publication normalized formatting in 13 Solidity library files but retained pre-formatting hashes. This copy verifies Solidity token equivalence against the official pinned release archives and refreshes those hashes; library source files themselves are unchanged.

| Dependency | Pin | Included files | License |
|---|---|---|---|
| OpenZeppelin Contracts | v5.1.0 | Required ERC20/ERC721, SafeERC20, Math, and transitive sources under `lib/openzeppelin-contracts` | MIT, included `LICENSE` |
| forge-std | v1.9.7 | `src` and licenses under `lib/forge-std` | MIT / Apache-2.0, included licenses |
| ethers | 6.13.5 | Browser UMD distribution under `web/vendor` | MIT, included license |

Source downloads: [OpenZeppelin release](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0), [forge-std release](https://github.com/foundry-rs/forge-std/tree/v1.9.7), [ethers distribution](https://www.npmjs.com/package/ethers/v/6.13.5).

Runtime protocol sources are not compiled into this project. Minimal ABI declarations and concrete call adapters are provided in `src`. Their trust assumptions and source references are recorded in `docs/deployment.md`. Foundry and solc are execution tools supplied by the check environment, not repository dependencies. The compiler is version-pinned in `foundry.toml`, not path-pinned.
