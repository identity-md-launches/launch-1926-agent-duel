# Agent Duel (AD)

Agent Duel is an immutable, fixed-supply ERC-20 on Ethereum. Its only custom
behavior is creating the requested supply in its constructor; transfers and
allowances use the vendored OpenZeppelin Contracts v5.0.2 implementation.

## Token and deployment parameters

| Parameter | Value |
| --- | --- |
| Solidity contract | `AgentDuel` |
| Source / artifact | `src/AgentDuel.sol` / `out/AgentDuel.sol/AgentDuel.json` |
| Token name | `Agent Duel` |
| Symbol | `AD` |
| Decimals | `18` |
| Supply | `1,000,000,000 AD` |
| Supply in base units | `1000000000000000000000000000` (`10^27`) |
| Named supply constant | `INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18` |
| Constructor arguments | None (`[]`) |
| Constructor ETH value | `0` |
| Initial recipient | The immediate deploying caller (`msg.sender`) |
| Target chain | Ethereum, chain ID `1` |
| Compiler / EVM target | Solidity `0.8.26` / Cancun |
| Optimizer / metadata | Enabled, 200 runs / `bytecode_hash = "none"` |

The constructor mints the entire supply once and emits the ERC-20 mint
`Transfer` event. In a factory deployment, the factory receives all tokens;
the transaction origin and the party calling the factory receive none from
the constructor. Direct deployment gives the entire supply to that deployer.
No constructor calls, address configuration, owner, initializer, or post-deploy
setup are needed. The creation bytecode has no external library links.

## Behavior and assumptions

- Standard `transfer`, `approve`, `transferFrom`, `balanceOf`, `allowance`, and
  metadata getters are available. Amounts are integers in 18-decimal base units.
- Transfers deliver the exact amount. There are no token taxes, transfer burns,
  rebases, transaction limits, or address exemptions.
- Zero-value transfers between nonzero addresses are valid and emit `Transfer`.
  Self-transfers preserve balances but still require enough balance.
- Successful transfers and approvals return `true`. Invalid recipients,
  insufficient balances, invalid spenders, and insufficient allowances revert
  with the inherited ERC-6093 custom errors; failed calls leave state unchanged.
- `approve` replaces an allowance, and approving zero revokes it. Finite
  allowances decrease on `transferFrom`; `type(uint256).max` remains unchanged.
  Explicit approvals emit `Approval`; spending an allowance does not emit a
  separate `Approval` event in this implementation.
- There is no callable mint or burn function. There are no owner privileges,
  pause, blacklist, seizure, proxy, upgrade, or rescue functions. The deployer
  has the same transfer and approval permissions as any holder after minting.
- The token makes no external calls during construction or transfers. There are
  no hooks, oracle dependencies, callbacks, signatures, or randomness.

## Build and check

Run from the repository root with Foundry and Solidity 0.8.26 installed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xd5545c9ed1e6402a9c6936d44c7d1d7afd25d87b6591d96ed22501443305517e forge test
forge fmt --check
```

All Solidity dependencies are ordinary files under `lib/`; no dependency
installation, network, RPC, submodule, FFI, or filesystem permission is needed
to run the suite. Foundry must already have the pinned compiler available when
building without a network. Tests do not read environment variables or fork a
chain. The command above supplies the requested seed to Foundry itself.

`test/AgentDuel.t.sol` covers constructor supply and its event, CREATE2 factory
deployment, standard transfer and allowance behavior, zero/self/max-value
cases, unauthorized spending, approval revocation, atomic rollback on failure,
absent admin entrypoints, exact launch-role token handoffs, and runtime opcode
and size restrictions. Four fuzz properties each run 1,000 cases.

`test/AgentDuel.invariant.t.sol` checks randomized transfers, approvals, and
delegated transfers against an independent balance and allowance model. It
runs 256 sequences of 64 calls, checking constant supply and conservation
after each call; unexpected handler reverts fail the test.

The launch-role handoff test checks ERC-20 movements with local actors. It does
not simulate Uniswap pricing, liquidity accounting, or Merkle proofs. The
provided protected suite depends on the launch system's contracts and manifest
environment and is run separately by that system; this repository does not
recreate that harness.

## Launch and operating responsibilities

The launch system deploys the compiled `AgentDuel` creation bytecode with no
arguments and no ETH. It supplies the manifest after this build is accepted;
this project does not include `launch.json`, a funded signer, or a broadcast
script. No transactions are sent by the tests.

Immediately after construction, the deploying factory holds all supply.
Allocation and pool operations are the factory's responsibility, outside the
token contract:

- 10% (`100,000,000 AD`) goes to the launch's Merkle distributor.
- 80% (`800,000,000 AD`) is allocated to pool seeding.
- The remaining 10% (`100,000,000 AD`) goes to
  `0x206f5dbf4f135c6183b5a5b99327fa0be34cb4d9`.

The supplied launch economics are `poolBps = 8000` and
`initialMarketCapWei = "3500000000000000000000"`, denominated in the Ethereum
IMD pair token (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals).
The launch's pool fee is `12500` (1.25%), tick spacing is `60`, and manifest
initial-price value is `"79228162514264337593543950336"`. The launch system
derives the actual opening price from the supplied economics and token ordering.
These supplied values are documented for handoff; they are not constructor
arguments or configurable token features. The token has no dependency on any
of these addresses.

After launch, there are no token settings to configure or administrator duties.
The launch operator is responsible for verifying deployed bytecode and source,
confirming metadata and supply, and completing the distribution and pool setup.
Holders are responsible for key custody, recipient selection, and spender
approvals. Use limited approvals where practical; when changing a live
allowance, revoke it and wait for confirmation before granting its replacement
to reduce the usual ERC-20 allowance replacement race.

Tokens sent to a contract that cannot transfer them back, including this token
contract itself, cannot be rescued. The zero address is rejected as a transfer
recipient. There is no payable fallback or ETH recovery mechanism.

The local verification consists of Foundry build, unit/fuzz/invariant tests,
format checks, and source review against the supplied security checklist.
All 32 tests passed with the seed above: 27 unit tests, 4 fuzz tests with 1,000
cases each, and 1 invariant test with 16,384 handler calls and zero reverts.
`forge build`, `forge fmt --check`, and dependency checksum verification passed.
Slither and Mythril were not run. These checks are not an independent security
audit; the launch's independent review remains a separate release step.

## Dependencies

See [DEPENDENCIES.md](DEPENDENCIES.md) for exact versions, source archives,
vendored file scope, checksums, and licenses.
