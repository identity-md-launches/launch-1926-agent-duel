# Vendored dependencies

Dependencies are committed as ordinary source files, with no submodules or
package-manager install step. Their upstream license files are included.

| Dependency | Pinned version | Included files | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | `v5.0.2` | `ERC20.sol`, `IERC20.sol`, `IERC20Metadata.sol`, `Context.sol`, `draft-IERC6093.sol` | MIT |
| Foundry forge-std | `v1.9.7` | Full `src/` directory, for tests | MIT or Apache-2.0 |

The OpenZeppelin subset contains the entire import closure needed by this
token. No optional token extensions are imported. Library Solidity files were
copied without edits from the tagged source archives:

- https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.0.2
- https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7

`vendor-checksums.sha256` records the SHA-256 of every vendored source and license
file. Check local integrity from the repository root with:

```sh
sha256sum -c vendor-checksums.sha256
```

Upstream OpenZeppelin files carry their last-change version in comments, which
can be older than the release tag. The pinned version here identifies the
archive used, not those per-file comments.
