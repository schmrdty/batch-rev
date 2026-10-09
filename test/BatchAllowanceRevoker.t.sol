// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BatchAllowanceRevoker} from "../src/BatchAllowanceRevoker.sol";
import {
    MockERC20,
    NoReturnToken,
    FalseReturnToken,
    RevertingToken,
    ShortReturnToken,
    ReentrantToken
} from "./Mocks.sol";

contract BatchAllowanceRevokerTest is Test {
    BatchAllowanceRevoker internal impl;
    /// @dev The delegated EOA viewed through the delegate ABI.
    BatchAllowanceRevoker internal account;

    address internal eoa = makeAddr("eoa");
    address internal stranger = makeAddr("stranger");
    address internal spender = makeAddr("spender");

    MockERC20 internal usdc;
    MockERC20 internal dai;
    NoReturnToken internal usdt;

    event Revoked(address indexed account, address indexed token, address indexed spender);

    function setUp() public {
        impl = new BatchAllowanceRevoker();
        usdc = new MockERC20();
        dai = new MockERC20();
        usdt = new NoReturnToken();

        // Simulate EIP-7702: the EOA runs the delegate's runtime code. SELF is an immutable baked
        // into that code, so it still points at the standalone deployment exactly as on-chain.
        vm.etch(eoa, address(impl).code);
        account = BatchAllowanceRevoker(payable(eoa));
    }

    // ------------------------------------------------------------------ helpers

    function _one(address token, address spender_) internal pure returns (BatchAllowanceRevoker.Revocation[] memory r) {
        r = new BatchAllowanceRevoker.Revocation[](1);
        r[0] = BatchAllowanceRevoker.Revocation(token, spender_);
    }

    function _many(address token, uint256 n) internal returns (BatchAllowanceRevoker.Revocation[] memory r) {
        r = new BatchAllowanceRevoker.Revocation[](n);
        for (uint256 i; i < n; ++i) {
            address s = address(uint160(uint256(keccak256(abi.encode("spender", i)))));
            MockERC20(token).seed(eoa, s, 1000);
            r[i] = BatchAllowanceRevoker.Revocation(token, s);
        }
    }

    function _revokeAsEoa(BatchAllowanceRevoker.Revocation[] memory r) internal {
        vm.prank(eoa);
        account.revokeMany(r);
    }

    // ------------------------------------------------------------------ constants / wiring

    function test_ConstantsAndDelegationWiring() public view {
        assertEq(impl.MAX_BATCH(), 100);
        assertEq(impl.SELF(), address(impl));
        assertEq(account.SELF(), address(impl), "SELF must still point at the standalone deployment");
        assertEq(eoa.code, address(impl).code);
    }

    // ------------------------------------------------------------------ input validation

    function test_RevertEmptyBatch() public {
        BatchAllowanceRevoker.Revocation[] memory r;
        vm.expectRevert(BatchAllowanceRevoker.EmptyBatch.selector);
        _revokeAsEoa(r);
    }

    function test_RevertBatchTooLarge() public {
        BatchAllowanceRevoker.Revocation[] memory r = _many(address(usdc), 101);
        vm.expectRevert(BatchAllowanceRevoker.BatchTooLarge.selector);
        _revokeAsEoa(r);
    }

    function test_RevertZeroToken() public {
        vm.expectRevert(BatchAllowanceRevoker.ZeroToken.selector);
        _revokeAsEoa(_one(address(0), spender));
    }

    function test_RevertZeroSpender() public {
        vm.expectRevert(BatchAllowanceRevoker.ZeroSpender.selector);
        _revokeAsEoa(_one(address(usdc), address(0)));
    }

    // ------------------------------------------------------------------ happy paths

    function test_SingleRevoke() public {
        usdc.seed(eoa, spender, 1000);
        assertEq(usdc.allowance(eoa, spender), 1000);

        vm.expectEmit(true, true, true, true, eoa);
        emit Revoked(eoa, address(usdc), spender);
        _revokeAsEoa(_one(address(usdc), spender));

        assertEq(usdc.allowance(eoa, spender), 0);
    }

    function test_MultiTokenRevokeIncludingNoReturnToken() public {
        usdc.seed(eoa, spender, 1);
        dai.seed(eoa, spender, type(uint256).max);
        usdt.seed(eoa, spender, 123);

        BatchAllowanceRevoker.Revocation[] memory r = new BatchAllowanceRevoker.Revocation[](3);
        r[0] = BatchAllowanceRevoker.Revocation(address(usdc), spender);
        r[1] = BatchAllowanceRevoker.Revocation(address(dai), spender);
        r[2] = BatchAllowanceRevoker.Revocation(address(usdt), spender);
        _revokeAsEoa(r);

        assertEq(usdc.allowance(eoa, spender), 0);
        assertEq(dai.allowance(eoa, spender), 0);
        assertEq(usdt.allowance(eoa, spender), 0);
    }

    function test_DuplicateEntriesSucceed() public {
        usdc.seed(eoa, spender, 5);
        BatchAllowanceRevoker.Revocation[] memory r = new BatchAllowanceRevoker.Revocation[](3);
        r[0] = BatchAllowanceRevoker.Revocation(address(usdc), spender);
        r[1] = r[0];
        r[2] = r[0];
        _revokeAsEoa(r);
        assertEq(usdc.allowance(eoa, spender), 0);
    }

    function test_ExactlyMaxBatch() public {
        BatchAllowanceRevoker.Revocation[] memory r = _many(address(usdc), 100);
        _revokeAsEoa(r);
        for (uint256 i; i < 100; ++i) {
            assertEq(usdc.allowance(eoa, r[i].spender), 0);
        }
    }

    // ------------------------------------------------------------------ non-standard tokens

    function test_RevertFalseReturnToken() public {
        address t = address(new FalseReturnToken());
        vm.expectRevert(abi.encodeWithSelector(BatchAllowanceRevoker.ApprovalFailed.selector, t, spender));
        _revokeAsEoa(_one(t, spender));
    }

    function test_RevertRevertingToken() public {
        address t = address(new RevertingToken());
        vm.expectRevert(abi.encodeWithSelector(BatchAllowanceRevoker.ApprovalFailed.selector, t, spender));
        _revokeAsEoa(_one(t, spender));
    }

    function test_RevertShortReturnToken() public {
        address t = address(new ShortReturnToken());
        vm.expectRevert(abi.encodeWithSelector(BatchAllowanceRevoker.ApprovalFailed.selector, t, spender));
        _revokeAsEoa(_one(t, spender));
    }

    function test_RevertNonContractToken() public {
        address t = makeAddr("not-a-token");
        vm.expectRevert(abi.encodeWithSelector(BatchAllowanceRevoker.ApprovalFailed.selector, t, spender));
        _revokeAsEoa(_one(t, spender));
    }

    function test_BatchIsAtomic() public {
        usdc.seed(eoa, spender, 1000);
        address bad = address(new RevertingToken());
        BatchAllowanceRevoker.Revocation[] memory r = new BatchAllowanceRevoker.Revocation[](2);
        r[0] = BatchAllowanceRevoker.Revocation(address(usdc), spender);
        r[1] = BatchAllowanceRevoker.Revocation(bad, spender);

        vm.expectRevert(abi.encodeWithSelector(BatchAllowanceRevoker.ApprovalFailed.selector, bad, spender));
        _revokeAsEoa(r);

        assertEq(usdc.allowance(eoa, spender), 1000, "first revoke must have rolled back");
    }

    function test_ReentrantTokenCannotDriveAccount() public {
        ReentrantToken t = new ReentrantToken();
        t.seed(eoa, spender, 7);
        _revokeAsEoa(_one(address(t), spender));

        assertTrue(t.reentered());
        assertEq(bytes4(t.reentryRevertData()), BatchAllowanceRevoker.NotSelf.selector);
        assertEq(t.allowance(eoa, spender), 0);
    }

    // ------------------------------------------------------------------ ETH / fallback

    function test_StandaloneRejectsEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(impl).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(impl).balance, 0);
    }

    function test_DelegatedEoaStillReceivesEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = eoa.call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(eoa.balance, 1 ether);
    }

    function test_UnknownSelectorReverts() public {
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", stranger, 1);
        (bool ok,) = eoa.call(data);
        assertFalse(ok, "delegated EOA must reject unknown calldata");
        (ok,) = address(impl).call(data);
        assertFalse(ok, "standalone must reject unknown calldata");

        vm.deal(address(this), 1 ether);
        (ok,) = eoa.call{value: 1}(data);
        assertFalse(ok, "value + unknown calldata must revert");
    }

    // ------------------------------------------------------------------ 7702 guards

    function test_StandaloneRevertsNotDelegated() public {
        usdc.seed(address(impl), spender, 1);
        vm.expectRevert(BatchAllowanceRevoker.NotDelegated.selector);
        impl.revokeMany(_one(address(usdc), spender));
        assertEq(usdc.allowance(address(impl), spender), 1);
    }

    function test_StrangerRevertsNotSelf() public {
        usdc.seed(eoa, spender, 1000);
        vm.expectRevert(BatchAllowanceRevoker.NotSelf.selector);
        vm.prank(stranger);
        account.revokeMany(_one(address(usdc), spender));
        assertEq(usdc.allowance(eoa, spender), 1000);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_RandomBatchSizeNeverUnexpectedlyReverts(uint8 n) public {
        n = uint8(bound(n, 1, 100));
        BatchAllowanceRevoker.Revocation[] memory r = _many(address(usdc), n);
        _revokeAsEoa(r);
        for (uint256 i; i < n; ++i) {
            assertEq(usdc.allowance(eoa, r[i].spender), 0);
        }
    }

    /// @dev Only zero addresses and non-contract tokens fail validation; everything else succeeds.
    function testFuzz_OnlyZeroOrNonContractFail(address token, address spender_, uint8 kind) public {
        kind = kind % 3;
        if (kind == 0) token = address(0);
        if (kind == 1) vm.assume(token != address(0) && token.code.length == 0);
        if (kind == 2) token = address(usdc);

        if (token == address(0)) {
            vm.expectRevert(BatchAllowanceRevoker.ZeroToken.selector);
        } else if (spender_ == address(0)) {
            vm.expectRevert(BatchAllowanceRevoker.ZeroSpender.selector);
        } else if (token.code.length == 0) {
            vm.expectRevert(abi.encodeWithSelector(BatchAllowanceRevoker.ApprovalFailed.selector, token, spender_));
        } else {
            usdc.seed(eoa, spender_, 42);
        }
        _revokeAsEoa(_one(token, spender_));
        if (token == address(usdc) && spender_ != address(0)) {
            assertEq(usdc.allowance(eoa, spender_), 0);
        }
    }

    function testFuzz_RandomSpendersAllZeroed(address[] memory spenders) public {
        vm.assume(spenders.length > 0 && spenders.length <= 100);
        BatchAllowanceRevoker.Revocation[] memory r = new BatchAllowanceRevoker.Revocation[](spenders.length);
        for (uint256 i; i < spenders.length; ++i) {
            vm.assume(spenders[i] != address(0));
            dai.seed(eoa, spenders[i], type(uint256).max);
            r[i] = BatchAllowanceRevoker.Revocation(address(dai), spenders[i]);
        }
        _revokeAsEoa(r);
        for (uint256 i; i < spenders.length; ++i) {
            assertEq(dai.allowance(eoa, spenders[i]), 0);
        }
    }
}
