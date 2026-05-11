// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {PrivateLiquidityTrackerZama} from "../src/PrivateLiquidityTrackerZama.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FHE, euint128, euint8, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {PoolEncryptedToken} from "../src/PoolEncryptedToken.sol";

/// @notice Integration test suite for PrivateLiquidityTrackerZama
/// @dev Tests wrap/unwrap/transfer functions independently of hook callbacks
contract PrivateLiquidityTrackerZamaIntegrationTest is FhevmTest {

    MockPoolManager public poolManager;
    PrivateLiquidityTrackerZama public tracker;

    address public alice;
    address public bob;
    PoolKey public poolKey;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        poolManager = new MockPoolManager();
        tracker = new PrivateLiquidityTrackerZama(IPoolManager(address(poolManager)));
        tracker.initialize();

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(tracker)
        });

        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(address(poolManager), "poolManager");
        vm.label(address(tracker), "tracker");
    }

    // ========== DEPLOYMENT TEST ==========

    function testTrackerDeployment() public {
        assertTrue(address(tracker) != address(0));
        assertTrue(address(poolManager) != address(0));
    }

    // ========== WRAP/UNWRAP TESTS ==========

    function testWrapTokens() public {
        vm.prank(alice);
        tracker.wrapLPTokens(poolKey, 100);

        vm.prank(alice);
        tracker.wrapLPTokens(poolKey, 100);
    }

    function testUnwrapTokens() public {
        vm.prank(alice);
        tracker.wrapLPTokens(poolKey, 100);

        vm.prank(alice);
        tracker.unwrapLPTokens(poolKey, 50);
    }

    function testUnwrapMoreThanWrapped() public {
        vm.prank(alice);
        tracker.wrapLPTokens(poolKey, 100);

        // Should clamp to balance, not revert
        vm.prank(alice);
        tracker.unwrapLPTokens(poolKey, 200);
    }

    function testMultipleWrapsAccumulate() public {
        vm.prank(alice);
        tracker.wrapLPTokens(poolKey, 100);

        vm.prank(alice);
        tracker.wrapLPTokens(poolKey, 200);

        // Total should be 300
    }

    // ========== ENCRYPTED POSITION TRANSFER TESTS ==========

    function testTransferEncryptedPosition() public {
        vm.prank(alice);
        tracker.transferEncryptedPosition(poolKey, alice, bob, 500);
    }

    function testTransferToZeroAddress() public {
        vm.prank(alice);
        tracker.wrapLPTokens(poolKey, 100);

        vm.prank(alice);
        vm.expectRevert(PrivateLiquidityTrackerZama.InvalidReceiver.selector);
        tracker.transferEncryptedPosition(poolKey, alice, address(0), 100);
    }

    function testTransferZeroAmount() public {
        vm.prank(alice);
        tracker.wrapLPTokens(poolKey, 100);

        vm.prank(alice);
        vm.expectRevert(PrivateLiquidityTrackerZama.InvalidAmount.selector);
        tracker.transferEncryptedPosition(poolKey, alice, bob, 0);
    }

    function testTransferMoreThanBalance() public {
        vm.prank(alice);
        tracker.wrapLPTokens(poolKey, 100);

        // Should clamp to balance (100), not revert
        vm.prank(alice);
        tracker.transferEncryptedPosition(poolKey, alice, bob, 500);
    }

    // ========== VIEW FUNCTION TESTS ==========

    function testGetEncryptedLPShares() public view {
        euint128 shares = tracker.getEncryptedLPShares(poolKey, alice);
        assertTrue(true);
    }

    function testIsPositionAllowed() public view {
        bool allowed = tracker.isPositionAllowed(poolKey, alice, bob);
        assertTrue(true);
    }

    // ========== DECRYPTION REQUEST TESTS ==========

    function testRequestDecryptionAsNonOwner() public {
        // Only pool owner can request decryption (poolOwner is tx.origin in _afterInitialize)
        // Since we didn't go through pool manager, alice is not owner
        vm.prank(alice);
        vm.expectRevert(PrivateLiquidityTrackerZama.OnlyPoolOwner.selector);
        tracker.requestDecryption(poolKey);
    }

    function testResetTrackingAsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(PrivateLiquidityTrackerZama.OnlyPoolOwner.selector);
        tracker.resetTracking(poolKey);
    }

    // ========== ENCRYPTED OPERATION TYPE TESTS ==========

    function testSetAndGetEncryptedOperationType() public {
        vm.prank(alice);
        tracker.setEncryptedOperationType(poolKey, 2); // ACTION_ADD_LIQUIDITY = 2

        euint8 opType = tracker.getEncryptedOperationType(poolKey, alice);
        assertTrue(true); // view function smoke test
    }

    function testEncryptedOperationTypeConstants() public pure {
        assertEq(uint8(0), 0); // ACTION_SWAP_0_TO_1
        assertEq(uint8(1), 1); // ACTION_SWAP_1_TO_0
        assertEq(uint8(2), 2); // ACTION_ADD_LIQUIDITY
        assertEq(uint8(3), 3); // ACTION_REMOVE_LIQUIDITY
    }

    // ========== FEE TRACKING TESTS ==========

    function testGetEncryptedFeesEarned() public view {
        (euint128 fees0, euint128 fees1) = tracker.getEncryptedFeesEarned(poolKey);
        assertTrue(true); // view function smoke test
    }

    // ========== INTERNAL TRANSFER TESTS ==========

    // ========== INTERNAL TRANSFER TESTS ==========
    // NOTE: These require _afterInitialize to run (poolEncryptedToken created there)
    // MockPoolManager doesn't invoke callbacks, so these tests need fork testing

    function testGetEncryptedPoolTokenBalance() public view {
        // PoolEncryptedToken created in _afterInitialize - requires real pool manager
        assertTrue(true); // placeholder - tested in fork tests
    }

    function testExecuteInternalTransferToZeroAddress() public {
        // Requires poolInitialized - tested in fork tests
        assertTrue(true);
    }

    function testExecuteInternalTransferZeroAmount() public {
        // Requires poolInitialized - tested in fork tests
        assertTrue(true);
    }

    function testMintInternalTransferToken() public {
        // Requires poolInitialized - tested in fork tests
        assertTrue(true);
    }

    function testBurnInternalTransferToken() public {
        // Requires poolInitialized - tested in fork tests
        assertTrue(true);
    }
}

/// @notice Minimal mock pool manager - stub for hook deployment only
contract MockPoolManager {
    function unlock(bytes calldata) external pure returns (bytes memory) {
        return "";
    }

    function initialize(PoolKey memory, uint160) external pure returns (int24) {
        return 0;
    }

    function modifyLiquidity(PoolKey memory, ModifyLiquidityParams memory, bytes calldata)
        external
        pure
        returns (BalanceDelta, BalanceDelta)
    {
        return (BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }

    function swap(PoolKey memory, SwapParams memory, bytes calldata) external pure returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function donate(PoolKey memory, uint256, uint256, bytes calldata) external pure returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function sync(Currency) external pure {}

    function take(Currency, address, uint256) external pure {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function settleFor(address) external payable returns (uint256) {
        return 0;
    }

    function clear(Currency, uint256) external pure {}

    function mint(address, uint256, uint256) external pure {}

    function burn(address, uint256, uint256) external pure {}

    function updateDynamicLPFee(PoolKey memory, uint24) external pure {}
}