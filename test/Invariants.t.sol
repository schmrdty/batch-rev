// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {BatchAllowanceRevoker} from "../src/BatchAllowanceRevoker.sol";
import {MockERC20} from "./Mocks.sol";

/// @dev Drives the delegated EOA, a stranger and the standalone deployment with random inputs.
///      Every call is wrapped so reverts never abort a run; the invariants below must hold regardless.
contract Handler is CommonBase, StdCheats, StdUtils {
    BatchAllowanceRevoker public immutable impl;
    address public immutable eoa;
    address public immutable stranger;
    MockERC20 public immutable token;
    address[] internal spenders;

    uint256 public successfulRevokes;

    constructor(BatchAllowanceRevoker impl_, address eoa_, address stranger_, MockERC20 token_) {
        impl = impl_;
        eoa = eoa_;
        stranger = stranger_;
        token = token_;
        for (uint256 i; i < 16; ++i) {
            spenders.push(address(uint160(uint256(keccak256(abi.encode("inv-spender", i))))));
        }
    }

    function _batch(uint256 n, uint256 seed) internal view returns (BatchAllowanceRevoker.Revocation[] memory r) {
        r = new BatchAllowanceRevoker.Revocation[](n);
        for (uint256 i; i < n; ++i) {
            r[i] = BatchAllowanceRevoker.Revocation(address(token), spenders[(seed + i) % spenders.length]);
        }
    }

    function revokeAsEoa(uint8 n, uint256 seed) external {
        n = uint8(bound(n, 0, 110));
        vm.prank(eoa);
        try BatchAllowanceRevoker(payable(eoa)).revokeMany(_batch(n, seed)) {
            successfulRevokes++;
        } catch {}
    }

    function revokeAsStranger(uint8 n, uint256 seed) external {
        n = uint8(bound(n, 1, 100));
        vm.prank(stranger);
        try BatchAllowanceRevoker(payable(eoa)).revokeMany(_batch(n, seed)) {} catch {}
    }

    function revokeOnStandalone(uint8 n, uint256 seed) external {
        n = uint8(bound(n, 1, 100));
        try impl.revokeMany(_batch(n, seed)) {} catch {}
    }

    function reseed(uint8 idx, uint128 amount) external {
        token.seed(eoa, spenders[idx % spenders.length], amount);
    }

    function sendEthToStandalone(uint96 amount) external {
        vm.deal(address(this), amount);
        (bool ok,) = address(impl).call{value: amount}("");
        ok;
    }

    function sendEthToEoa(uint96 amount) external {
        vm.deal(address(this), amount);
        (bool ok,) = eoa.call{value: amount}("");
        ok;
    }

    function arbitraryCalldata(bytes4 selector, bytes calldata tail) external {
        bytes memory data = abi.encodePacked(selector, tail);
        vm.prank(eoa);
        (bool ok,) = eoa.call(data);
        (ok,) = address(impl).call(data);
        ok;
    }
}

contract BatchAllowanceRevokerInvariants is Test {
    BatchAllowanceRevoker internal impl;
    MockERC20 internal token;
    Handler internal handler;

    address internal eoa = makeAddr("eoa");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        impl = new BatchAllowanceRevoker();
        token = new MockERC20();
        vm.etch(eoa, address(impl).code);
        handler = new Handler(impl, eoa, stranger, token);
        targetContract(address(handler));
    }

    /// @dev The standalone deployment can never hold ETH.
    function invariant_StandaloneNeverHoldsEth() public view {
        assertEq(address(impl).balance, 0);
    }

    /// @dev The delegated account never approves a non-zero amount.
    function invariant_NeverApprovesNonZero() public view {
        assertEq(token.nonZeroApproveFromCode(), 0);
    }

    /// @dev Neither the delegate nor the standalone deployment ever calls transfer/transferFrom.
    function invariant_NeverTransfersTokens() public view {
        assertEq(token.transferCalls(), 0);
    }

    /// @dev The delegate writes no storage on the delegated account and its code is unchanged.
    function invariant_NoStorageOrCodeChangesOnAccount() public view {
        for (uint256 slot; slot < 8; ++slot) {
            assertEq(vm.load(eoa, bytes32(slot)), bytes32(0));
        }
        assertEq(eoa.code, address(impl).code);
    }
}
