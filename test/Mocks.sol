// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BatchAllowanceRevoker} from "../src/BatchAllowanceRevoker.sol";

/// @dev Standard ERC-20 approve surface plus instrumentation used by the invariant suite.
contract MockERC20 {
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev Number of approve() calls with a non-zero amount made by an account that has code
    ///      (i.e. the 7702-delegated EOA). Must stay 0 forever.
    uint256 public nonZeroApproveFromCode;
    /// @dev Number of transfer()/transferFrom() calls, from anyone. Must stay 0 forever.
    uint256 public transferCalls;

    function approve(address spender, uint256 amount) external virtual returns (bool) {
        allowance[msg.sender][spender] = amount;
        if (amount != 0 && msg.sender.code.length != 0) nonZeroApproveFromCode++;
        return true;
    }

    /// @dev Test-only: set an allowance without going through approve().
    function seed(address owner, address spender, uint256 amount) external {
        allowance[owner][spender] = amount;
    }

    function transfer(address, uint256) external returns (bool) {
        transferCalls++;
        return true;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        transferCalls++;
        return true;
    }
}

/// @dev USDT-style: approve() returns no data.
contract NoReturnToken {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function seed(address owner, address spender, uint256 amount) external {
        allowance[owner][spender] = amount;
    }
}

/// @dev approve() returns false.
contract FalseReturnToken {
    function approve(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev approve() reverts.
contract RevertingToken {
    function approve(address, uint256) external pure returns (bool) {
        revert("nope");
    }
}

/// @dev approve() returns a single byte (malformed return data).
contract ShortReturnToken {
    function approve(address, uint256) external pure returns (bool) {
        assembly {
            mstore(0, 1)
            return(0, 1)
        }
    }
}

/// @dev approve() tries to re-enter revokeMany on the calling account.
contract ReentrantToken {
    mapping(address => mapping(address => uint256)) public allowance;
    bool public reentered;
    bytes public reentryRevertData;

    function approve(address spender, uint256 amount) external returns (bool) {
        if (!reentered) {
            reentered = true;
            BatchAllowanceRevoker.Revocation[] memory r = new BatchAllowanceRevoker.Revocation[](1);
            r[0] = BatchAllowanceRevoker.Revocation(address(this), spender);
            (bool ok, bytes memory data) = msg.sender.call(abi.encodeCall(BatchAllowanceRevoker.revokeMany, (r)));
            require(!ok, "reentry must fail");
            reentryRevertData = data;
        }
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function seed(address owner, address spender, uint256 amount) external {
        allowance[owner][spender] = amount;
    }
}
