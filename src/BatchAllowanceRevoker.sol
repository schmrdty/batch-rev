// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title BatchAllowanceRevoker
/// @notice Immutable, ownerless EIP-7702 delegate that can do exactly one thing:
///         set ERC-20 allowances of the executing account to zero, in batch.
/// @dev Designed to run ONLY as EIP-7702 delegated code of an EOA. Executed on the
///      standalone deployment it is inert: `revokeMany` reverts with `NotDelegated` so a
///      user can never be tricked into "revoking" the contract's own (empty) allowances.
///      No owner, no proxy, no storage, no arbitrary calls, no token movement.
contract BatchAllowanceRevoker {
    error EmptyBatch();
    error BatchTooLarge();
    error ZeroToken();
    error ZeroSpender();
    error ApprovalFailed(address token, address spender);
    error NotDelegated();
    error NotSelf();
    error NoEther();

    /// @notice Hard cap on revocations per call (gas-exhaustion bound).
    uint256 public constant MAX_BATCH = 100;

    /// @notice Address of the standalone deployment. Inside a 7702 delegation
    ///         `address(this)` is the user's EOA and therefore differs from SELF.
    address public immutable SELF;

    struct Revocation {
        address token;
        address spender;
    }

    event Revoked(address indexed account, address indexed token, address indexed spender);

    constructor() {
        SELF = address(this);
    }

    /// @notice Set allowance(account, spender) to zero for every (token, spender) pair.
    /// @dev Only callable by the delegated account itself (msg.sender == address(this)),
    ///      which in a 7702 context means the EOA signed the transaction. This blocks
    ///      third parties from griefing a delegated account by zeroing its approvals.
    function revokeMany(Revocation[] calldata revocations) external {
        if (address(this) == SELF) revert NotDelegated();
        if (msg.sender != address(this)) revert NotSelf();

        uint256 length = revocations.length;
        if (length == 0) revert EmptyBatch();
        if (length > MAX_BATCH) revert BatchTooLarge();

        for (uint256 i = 0; i < length;) {
            address token = revocations[i].token;
            address spender = revocations[i].spender;
            if (token == address(0)) revert ZeroToken();
            if (spender == address(0)) revert ZeroSpender();

            _approveZero(token, spender);
            emit Revoked(address(this), token, spender);

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Equivalent to OpenZeppelin SafeERC20.forceApprove(token, spender, 0):
    ///      tolerates tokens that return nothing (USDT-style), requires `true` when a
    ///      boolean is returned, and reverts on call failure or non-contract targets.
    ///      The amount is a hard-coded literal 0 — there is no code path that can
    ///      encode any other value.
    function _approveZero(address token, address spender) private {
        if (token.code.length == 0) revert ApprovalFailed(token, spender);
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, uint256(0)));
        if (!ok || (ret.length != 0 && !(ret.length >= 32 && abi.decode(ret, (bool))))) {
            revert ApprovalFailed(token, spender);
        }
    }

    /// @dev Standalone deployment refuses ETH (it can never move it). A 7702-delegated
    ///      EOA keeps receiving plain ETH transfers as normal.
    receive() external payable {
        if (address(this) == SELF) revert NoEther();
    }

    fallback() external payable {
        revert NoEther();
    }
}
