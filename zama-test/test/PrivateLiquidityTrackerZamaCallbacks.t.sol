// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {PrivateLiquidityTrackerZama} from "../src/PrivateLiquidityTrackerZama.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// @notice Test contract that exposes hook callbacks as external methods for testing
contract TestablePrivateLiquidityTrackerZama is PrivateLiquidityTrackerZama {
    using PoolIdLibrary for PoolKey;

    constructor(IPoolManager _poolManager) PrivateLiquidityTrackerZama(_poolManager) {}

    function callAfterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external returns (bytes4) {
        return _afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    function callBeforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        return _beforeAddLiquidity(sender, key, params, hookData);
    }

    function callAfterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        return _afterAddLiquidity(sender, key, params, delta, feesAccrued, hookData);
    }

    function callBeforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        return _beforeRemoveLiquidity(sender, key, params, hookData);
    }

    function callAfterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        return _afterRemoveLiquidity(sender, key, params, delta, feesAccrued, hookData);
    }

    function userHasAccessForPool(PoolKey calldata key, address user) external view returns (bool) {
        PoolId poolId = key.toId();
        return hasAccess[poolId][user];
    }
}

/// @notice Test PoolManager that invokes hook callbacks
contract TestPoolManager is Test {
    using PoolIdLibrary for PoolKey;

    TestablePrivateLiquidityTrackerZama public hook;

    constructor() {
        hook = new TestablePrivateLiquidityTrackerZama(IPoolManager(address(this)));
        hook.initialize();
    }

    function sortTokens(address tokenA, address tokenB) internal pure returns (Currency, Currency) {
        if (tokenA < tokenB) {
            return (Currency.wrap(tokenA), Currency.wrap(tokenB));
        }
        return (Currency.wrap(tokenB), Currency.wrap(tokenA));
    }

    function callAfterInitialize(
        TestablePrivateLiquidityTrackerZama tracker,
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) public returns (bytes4) {
        return tracker.callAfterInitialize(sender, key, sqrtPriceX96, tick);
    }

    function callAddLiquidity(
        TestablePrivateLiquidityTrackerZama tracker,
        address sender,
        PoolKey calldata key,
        int256 liquidityDelta,
        bytes calldata hookData
    ) public returns (bytes4, bytes4, BalanceDelta) {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: 0,
            tickUpper: 0,
            liquidityDelta: liquidityDelta,
            salt: bytes32(0)
        });

        bytes4 beforeResult = tracker.callBeforeAddLiquidity(sender, key, params, hookData);

        BalanceDelta delta = BalanceDelta.wrap(int256(liquidityDelta) * 1e18);
        BalanceDelta fees = BalanceDelta.wrap(0);
        (bytes4 afterResult, BalanceDelta returnedDelta) =
            tracker.callAfterAddLiquidity(sender, key, params, delta, fees, hookData);

        return (beforeResult, afterResult, returnedDelta);
    }

    function callRemoveLiquidity(
        TestablePrivateLiquidityTrackerZama tracker,
        address sender,
        PoolKey calldata key,
        int256 liquidityDelta,
        bytes calldata hookData
    ) public returns (bytes4, bytes4, BalanceDelta) {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: 0,
            tickUpper: 0,
            liquidityDelta: liquidityDelta,
            salt: bytes32(0)
        });

        bytes4 beforeResult = tracker.callBeforeRemoveLiquidity(sender, key, params, hookData);

        BalanceDelta delta = BalanceDelta.wrap(int256(liquidityDelta) * 1e18);
        BalanceDelta fees = BalanceDelta.wrap(0);
        (bytes4 afterResult, BalanceDelta returnedDelta) =
            tracker.callAfterRemoveLiquidity(sender, key, params, delta, fees, hookData);

        return (beforeResult, afterResult, returnedDelta);
    }

    function unlock(bytes calldata) external pure returns (bytes memory) {
        return "";
    }
}

/// @notice Integration tests for PrivateLiquidityTrackerZama hook callbacks
contract PrivateLiquidityTrackerZamaCallbacksTest is FhevmTest {
    using PoolIdLibrary for PoolKey;

    TestPoolManager public poolManager;
    TestablePrivateLiquidityTrackerZama public tracker;
    address public alice;
    address public bob;
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        poolManager = new TestPoolManager();
        tracker = poolManager.hook();

        MockERC20 token0 = new MockERC20();
        MockERC20 token1 = new MockERC20();

        (Currency currency0, Currency currency1) = _sortTokens(address(token0), address(token1));
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(tracker)
        });
        poolId = poolKey.toId();

        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(address(poolManager), "poolManager");
        vm.label(address(tracker), "tracker");
    }

    function _sortTokens(address tokenA, address tokenB) internal pure returns (Currency, Currency) {
        if (tokenA < tokenB) {
            return (Currency.wrap(tokenA), Currency.wrap(tokenB));
        }
        return (Currency.wrap(tokenB), Currency.wrap(tokenA));
    }

    // ========== AFTER INITIALIZE TESTS ==========

    function test_AfterInitialize_ReturnsCorrectSelector() public {
        bytes4 result = poolManager.callAfterInitialize(tracker, alice, poolKey, 79228162514264337593543950336, 0);
        assertEq(result, BaseHook.afterInitialize.selector);
    }

    // ========== ADD LIQUIDITY TESTS ==========

    function test_BeforeAddLiquidity_ReturnsCorrectSelector() public {
        int256 liquidityDelta = 1000000;

        (bytes4 beforeResult, , ) = poolManager.callAddLiquidity(tracker, alice, poolKey, liquidityDelta, "");

        assertEq(beforeResult, BaseHook.beforeAddLiquidity.selector);
    }

    function test_AfterAddLiquidity_ReturnsCorrectSelector() public {
        int256 liquidityDelta = 1000000;

        (, bytes4 afterResult, ) = poolManager.callAddLiquidity(tracker, alice, poolKey, liquidityDelta, "");

        assertEq(afterResult, BaseHook.afterAddLiquidity.selector);
    }

    // ========== REMOVE LIQUIDITY TESTS ==========

    function test_BeforeRemoveLiquidity_ReturnsCorrectSelector() public {
        int256 liquidityDelta = -500000;

        poolManager.callAddLiquidity(tracker, alice, poolKey, 1000000, "");

        (bytes4 beforeResult, , ) = poolManager.callRemoveLiquidity(tracker, alice, poolKey, liquidityDelta, "");

        assertEq(beforeResult, BaseHook.beforeRemoveLiquidity.selector);
    }

    function test_AfterRemoveLiquidity_ReturnsCorrectSelector() public {
        int256 liquidityDelta = -500000;

        poolManager.callAddLiquidity(tracker, alice, poolKey, 1000000, "");

        (, bytes4 afterResult, ) = poolManager.callRemoveLiquidity(tracker, alice, poolKey, liquidityDelta, "");

        assertEq(afterResult, BaseHook.afterRemoveLiquidity.selector);
    }

    // ========== FULL FLOW TESTS ==========

    function test_FullLiquidityFlow_AddThenRemove() public {
        int256 addDelta = 1000000;
        poolManager.callAddLiquidity(tracker, alice, poolKey, addDelta, "");

        int256 removeDelta = -500000;
        poolManager.callRemoveLiquidity(tracker, alice, poolKey, removeDelta, "");
    }

    function test_MultipleUsers_IndependentTracking() public {
        poolManager.callAddLiquidity(tracker, alice, poolKey, 1000000, "");
        poolManager.callAddLiquidity(tracker, bob, poolKey, 2000000, "");
    }

    // ========== ACCESS CONTROL TESTS ==========

    function test_AfterAddLiquidity_GrantsUserAccess() public {
        poolManager.callAddLiquidity(tracker, alice, poolKey, 1000000, "");

        assertTrue(tracker.userHasAccessForPool(poolKey, alice));
    }

    function test_RequestDecryption_OnlyPoolOwner() public {
        poolManager.callAfterInitialize(tracker, address(this), poolKey, 79228162514264337593543950336, 0);

        vm.prank(alice);
        vm.expectRevert(PrivateLiquidityTrackerZama.OnlyPoolOwner.selector);
        tracker.requestDecryption(poolKey);
    }

    function test_ResetTracking_OnlyPoolOwner() public {
        poolManager.callAfterInitialize(tracker, address(this), poolKey, 79228162514264337593543950336, 0);

        vm.prank(alice);
        vm.expectRevert(PrivateLiquidityTrackerZama.OnlyPoolOwner.selector);
        tracker.resetTracking(poolKey);
    }
}

/// @notice Simple ERC20 mock for testing
contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}