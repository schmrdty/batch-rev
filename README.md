# BatchAllowanceRevoker

Immutable, ownerless **EIP-7702 delegate** that can do exactly one thing: set ERC-20 allowances of the executing account to zero, in batch.

- 53 lines of functional Solidity, no dependencies.
- No owner. No proxy. No storage. No arbitrary calls. No token movement. Amount is the literal `0`.
- Deterministic CREATE2 deployment: the same bytecode + salt yields the same address on every chain.

## Deployments

| chain | address | status |
|---|---|---|
| Base (8453) | [`0xb8896a65b4da93d4cf6bb393124dfbd9d7a34c05`](https://basescan.org/address/0xb8896a65b4da93d4cf6bb393124dfbd9d7a34c05#code) | verified on Basescan |
| Robinhood Chain (4663) | [`0xb8896a65b4da93d4cf6bb393124dfbd9d7a34c05`](https://robin.etherscan.io/address/0xb8896a65b4da93d4cf6bb393124dfbd9d7a34c05#code) | verified on Etherscan |
| Ethereum mainnet | — | not yet deployed (pending real-world test on Base first) |
| Arbitrum, Polygon, Unichain, World Chain, BNB, Arc | — | not yet deployed; same bytecode + zero salt reproduces the same address |

initcode `keccak256`: `0x024958b0d57ad819ddc2307b76126d0b38a73fcb87753fd92ade680c72ac1d42`

Deployed through the canonical deterministic CREATE2 factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with the zero salt. Compiler: solc `0.8.26`, optimizer `1000000` runs, evm `paris`, `bytecodeHash = none`, `appendCBOR = false` (no metadata hash → bit-for-bit reproducible). [`standard-input.json`](standard-input.json) is the exact compiler input used for deployment and verification.

**Always check the delegate's code on the chain you are on before delegating to it.** An address being "the same" on another chain means nothing until the bytecode there has been verified (threat #12 in [SECURITY.md](SECURITY.md)).

Reproduce locally:

```sh
forge build --silent
forge inspect src/BatchAllowanceRevoker.sol:BatchAllowanceRevoker bytecode | tr -d '\n' | cast keccak
# → 0x024958b0d57ad819ddc2307b76126d0b38a73fcb87753fd92ade680c72ac1d42
```

## How it works (read this before using it)

`approve(spender, 0)` only affects `msg.sender`'s allowance. A normal contract calling `approve` zeroes **its own** allowances, not yours. This contract is therefore useless as a standalone contract and **only works when your EOA delegates to it via EIP-7702** (type-4 transaction with an authorization list). In that context `address(this)` is your EOA, so every `approve` call is made by you.

Two guards enforce that model:

- `NotDelegated` — `revokeMany` reverts when called on the standalone deployment (`address(this) == SELF`). Nobody can be tricked into "revoking" the contract's own empty allowances.
- `NotSelf` — `revokeMany` reverts unless `msg.sender == address(this)`, i.e. the delegated EOA signed the transaction itself. A third party cannot grief a delegated account by zeroing its approvals, and a malicious token cannot re-enter and drive the account.

If your wallet does not support EIP-7702, do not use this contract. Send plain `approve(spender, 0)` transactions directly to each token instead — the companion Bankr app does exactly that as its default path ("path A"); the 7702 batch is "path B".

### Interface

```solidity
struct Revocation { address token; address spender; }
function revokeMany(Revocation[] calldata revocations) external; // selector 0x4cc6f59e
uint256 public constant MAX_BATCH = 100;
address public immutable SELF;
event Revoked(address indexed account, address indexed token, address indexed spender);
```

Errors: `EmptyBatch`, `BatchTooLarge`, `ZeroToken`, `ZeroSpender`, `ApprovalFailed(token, spender)`, `NotDelegated`, `NotSelf`, `NoEther`.

### Non-standard tokens

`_approveZero` is a dependency-free equivalent of OpenZeppelin `SafeERC20.forceApprove(token, spender, 0)`:

- target must have code (reverts otherwise — a typo'd token address cannot silently "succeed");
- tokens returning nothing (USDT-style) pass;
- tokens returning a boolean must return `true`;
- short/garbage return data reverts.

The batch is atomic: one failing token rolls back the whole call. Fix or drop that entry and resubmit.

### ETH

The standalone deployment rejects all ETH (`NoEther`). A 7702-delegated EOA keeps receiving plain ETH transfers as normal; any call with calldata that does not match `revokeMany` reverts.

## Tests

`forge test` — 27 tests, all green:

- unit (20): constants/delegation wiring, empty batch, oversized batch, zero token, zero spender, single revoke, multi-token revoke incl. no-return token, duplicates, exactly `MAX_BATCH`, false-return token, reverting token, short-return token, non-contract token, atomic rollback, reentrant token, standalone rejects ETH, delegated EOA still receives ETH, unknown selector reverts, standalone `NotDelegated`, stranger `NotSelf`.
- fuzz (3 × 512 runs): random batch size 1–100 never unexpectedly reverts; only zero addresses / non-contracts fail validation; random spenders all zeroed.
- invariants (4 × 64 runs × 32 depth): standalone never holds ETH; never approves a non-zero amount; never calls `transfer`/`transferFrom`; never writes storage on the delegated account.

EIP-7702 is simulated with `vm.etch(eoa, impl.code)` — the EOA runs the delegate's runtime code while `SELF` still points at the standalone deployment, exactly as in a real delegation.

```sh
mkdir -p lib && curl -sL https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.6 | tar -xz -C lib && mv lib/forge-std-1.9.6 lib/forge-std
forge test
```

## Static analysis

Slither 0.11.3 ([`slither-report.txt`](slither-report.txt)) reports three findings, all triaged as by-design:

| finding | triage |
|---|---|
| locks ether (payable receive/fallback, no withdraw) | intentional — `receive` must be payable so a delegated EOA keeps accepting ETH; the standalone deployment reverts on any ETH, so nothing can get locked |
| external call in loop | the loop *is* the feature; bounded by `MAX_BATCH = 100` |
| event emitted after external call | no state to protect; the event is intentionally emitted only after a successful revoke (threat #6 — event spoofing) |

## CI

The workflow in [`ci/ci.yml`](ci/ci.yml) runs `forge fmt --check`, `forge build --sizes`, `forge test`, `forge snapshot --check`, asserts the initcode hash above, then Slither (`--fail-high`) and Semgrep (`p/smart-contracts`). It is staged under `ci/` because the connector that pushed this repo cannot write to `.github/workflows/`; move it to `.github/workflows/ci.yml` to enable it.

## Threat model

See [SECURITY.md](SECURITY.md).

## License

MIT
