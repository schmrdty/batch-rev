# Threat model & audit checklist

## Objectives

The contract has no owner, no upgradeability, holds no assets, cannot transfer user assets, cannot execute arbitrary calldata, can only call `approve(spender, 0)`, is deterministic and reproducible, and has a tiny attack surface.

## Non-goals

No arbitrary DeFi batching, no approving spenders, no moving ERC-20 funds, no NFTs (ERC-721 `setApprovalForAll` is out of scope), no plugins.

## Threats

| # | threat | impact | mitigation | residual |
|---|---|---|---|---|
| 1 | malicious frontend swaps `approve(spender,0)` for `transfer(attacker,amount)` | drain | contract exposes only `revokeMany`; amount is a literal `0`; unknown selectors revert | low — the frontend can still choose *which* approvals to revoke; see "frontend" below |
| 2 | upgrade attack | drain | no proxy / UUPS / beacon; immutable | none |
| 3 | private key compromise | full | out of scope | n/a |
| 4 | ERC-20 non-compliance | unexpected reverts | `_approveZero` tolerates no-return tokens, requires `true` when a bool is returned, rejects non-contracts and garbage returns | low |
| 5 | gas exhaustion | tx fails | `MAX_BATCH = 100` | none |
| 6 | event spoofing | UX confusion | `Revoked` emitted only after a successful call | none |
| 7 | reentrancy | — | no ETH transfers, no storage; a re-entering token hits `NotSelf` (tested) | none |
| 8 | **7702 griefing** — third party calls `revokeMany` on a delegated EOA | approvals zeroed without consent | `msg.sender == address(this)` required | none |
| 9 | **7702 ETH lock** — `receive()` reverting would stop a delegated EOA receiving ETH | funds stuck in flight | `receive` only reverts on the standalone deployment | none |
| 10 | **standalone misuse** — user sends `revokeMany` to the deployment address, believing their allowances were revoked | false sense of safety | `NotDelegated` revert | none |
| 11 | **delegation persistence** — EIP-7702 delegation stays set until replaced; code at the EOA address is this contract | any future bug in this contract applies to the account | contract is storage-less and single-purpose; users may re-delegate to `0x0` after use; document clearly | low |
| 12 | **wrong-chain address** — same CREATE2 address on another chain may be undeployed or (if the factory differs) hold other code | delegating to empty/foreign code | frontend must verify `extcodehash` of the delegate on the target chain before offering path B | mitigated by frontend |

## Frontend is the real attack surface

The contract can only zero allowances, so the worst a compromised frontend can do through it is revoke approvals the user did not intend to revoke (a nuisance, not a theft). The frontend must still:

- derive the revocation list from on-chain `Approval` logs + live `allowance()` reads, not from an opaque API;
- show the fully decoded calldata (selector, every token/spender, every amount == 0) before signing;
- `eth_call`-simulate the exact calldata against the user's account before signing;
- for path B, verify the delegate's `extcodehash` on the target chain matches the published runtime hash;
- never request any signature other than (a) `approve(spender, 0)` to a token or (b) `revokeMany` to the user's own address under 7702.

## Audit checklist

- [ ] No arbitrary execution (only `revokeMany`; `fallback` reverts).
- [ ] No upgradeability, no ownership controls, no storage.
- [ ] No hidden token movement (`transfer`/`transferFrom` selectors never encoded; invariant tested).
- [ ] Approve amount is a compile-time literal `0`.
- [ ] Events accurately represent actions (emitted after success only).
- [ ] Non-standard ERC-20 handling (no-return, false-return, short-return, non-contract).
- [ ] EIP-7702 assumptions: `SELF` guard, `msg.sender == address(this)` guard, `receive` behaviour under delegation, delegation persistence documented.
- [ ] Reproducible build: `bytecodeHash = none`, `appendCBOR = false`, pinned solc, CI asserts initcode hash.
- [ ] Deterministic address via canonical CREATE2 factory, zero salt.

## Reporting

Open a GitHub security advisory on this repository.
