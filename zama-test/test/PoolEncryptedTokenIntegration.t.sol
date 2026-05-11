// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {PoolEncryptedToken} from "../src/PoolEncryptedToken.sol";
import {PrivateLiquidityTrackerZama} from "../src/PrivateLiquidityTrackerZama.sol";
import {PrivateLiquidityTrackerZamaSubscriber} from "../src/PrivateLiquidityTrackerZamaSubscriber.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {FHE, euint64, euint128} from "@fhevm/solidity/lib/FHE.sol";
import {externalEuint64} from "encrypted-types/EncryptedTypes.sol";

// ========== TESTABLE HOOK ==========

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

    /// @notice Expose getEncryptedLPShares for testing
    function getEncryptedLPSharesExt(PoolKey calldata key, address user) external view returns (euint128) {
        return encryptedLPShares[key.toId()][user];
    }

    /// @notice Expose feeAccumulator0 for testing
    function getFeeAccumulator0(PoolId poolId) external view returns (euint128) {
        return feeAccumulator0[poolId];
    }

    /// @notice Expose feeAccumulator1 for testing
    function getFeeAccumulator1(PoolId poolId) external view returns (euint128) {
        return feeAccumulator1[poolId];
    }

    /// @notice Expose poolEncryptedTokens for testing
    function getPoolEncryptedToken(PoolId poolId) external view returns (PoolEncryptedToken) {
        return poolEncryptedTokens[poolId];
    }
}

// ========== TEST POOL MANAGER ==========

contract TestPoolManagerIntegration is Test {
    using PoolIdLibrary for PoolKey;

    TestablePrivateLiquidityTrackerZama public hook;

    constructor() {
        hook = new TestablePrivateLiquidityTrackerZama(IPoolManager(address(this)));
        hook.initialize();
    }

    function sortTokens(address tokenA, address tokenB) internal pure returns (Currency, Currency) {
        if (tokenA < tokenB) {
            return (Currency.wrap(tokenA), Currency.wrap(tokenA));
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

    function callAddLiquidityWithFees(
        TestablePrivateLiquidityTrackerZama tracker,
        address sender,
        PoolKey calldata key,
        int256 liquidityDelta,
        int128 feeAmount0,
        int128 feeAmount1,
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
        BalanceDelta fees = toBalanceDelta(feeAmount0, feeAmount1);
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

// ========== MOCK ERC20 ==========

contract MockERC20Integration {
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

// ========== POOL ENCRYPTED TOKEN TESTS (via hook) ==========

contract PoolEncryptedTokenTest is FhevmTest {
    using PoolIdLibrary for PoolKey;

    TestPoolManagerIntegration public poolManager;
    TestablePrivateLiquidityTrackerZama public tracker;
    PoolEncryptedToken public pet;
    address public alice;
    address public bob;
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        poolManager = new TestPoolManagerIntegration();
        tracker = poolManager.hook();

        MockERC20Integration token0 = new MockERC20Integration();
        MockERC20Integration token1 = new MockERC20Integration();

        (Currency currency0, Currency currency1) = _sortTokens(address(token0), address(token1));
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(tracker)
        });
        poolId = poolKey.toId();

        // Initialize pool (creates PoolEncryptedToken)
        poolManager.callAfterInitialize(tracker, alice, poolKey, SQRT_PRICE, 0);

        // Get PoolEncryptedToken created by the hook
        pet = tracker.getPoolEncryptedToken(poolId);

        vm.label(alice, "alice");
        vm.label(bob, "bob");
    }

    uint160 internal constant SQRT_PRICE = 79228162514264337593543950336;

    function _sortTokens(address tokenA, address tokenB) internal pure returns (Currency, Currency) {
        if (tokenA < tokenB) {
            return (Currency.wrap(tokenA), Currency.wrap(tokenB));
        }
        return (Currency.wrap(tokenB), Currency.wrap(tokenA));
    }

    // ========== MINT / BURN ==========

    function testMintIncreasesBalanceAndSupply() public {
        uint64 mintAmount = 1000;

        // Encrypt then convert to internal type
        (externalEuint64 encAmount, bytes memory proof) = encryptUint64(mintAmount, address(pet));
        euint64 amount = FHE.fromExternal(encAmount, proof);

        // Mint via hook
        pet.mint(alice, amount);

        // Decrypt and verify alice's balance
        euint64 aliceBal = pet.getEncryptedBalance(alice);
        uint256 clearAliceBal = decrypt(euint64.unwrap(aliceBal));
        assertEq(clearAliceBal, mintAmount, "alice balance should equal mint amount");

        // Decrypt and verify total supply
        euint64 totalSupply = pet.getTotalEncryptedSupply();
        uint256 clearSupply = decrypt(euint64.unwrap(totalSupply));
        assertEq(clearSupply, mintAmount, "total supply should equal mint amount");
    }

    function testBurnDecreasesBalanceAndSupply() public {
        uint64 mintAmount = 1000;
        (externalEuint64 encMint, bytes memory proof) = encryptUint64(mintAmount, address(pet));
        pet.mint(alice, FHE.fromExternal(encMint, proof));

        uint64 burnAmount = 400;
        (externalEuint64 encBurn, bytes memory burnProof) = encryptUint64(burnAmount, address(pet));
        pet.burn(alice, FHE.fromExternal(encBurn, burnProof));

        uint256 aliceBal = decrypt(euint64.unwrap(pet.getEncryptedBalance(alice)));
        assertEq(aliceBal, mintAmount - burnAmount, "alice balance should decrease");

        uint256 totalSupply = decrypt(euint64.unwrap(pet.getTotalEncryptedSupply()));
        assertEq(totalSupply, mintAmount - burnAmount, "supply should decrease");
    }

    function testBurnClampsToBalance() public {
        // Mint only 200
        (externalEuint64 encMint, bytes memory proof) = encryptUint64(200, address(pet));
        pet.mint(alice, FHE.fromExternal(encMint, proof));

        // Try to burn 500 (more than balance)
        (externalEuint64 encBurn, bytes memory burnProof) = encryptUint64(500, address(pet));
        pet.burn(alice, FHE.fromExternal(encBurn, burnProof));

        // Should have clamped to 200 and burned it all
        uint256 aliceBal = decrypt(euint64.unwrap(pet.getEncryptedBalance(alice)));
        assertEq(aliceBal, 0, "balance should be 0 after burning more than available");

        uint256 totalSupply = decrypt(euint64.unwrap(pet.getTotalEncryptedSupply()));
        assertEq(totalSupply, 0, "supply should be 0");
    }

    function testMultipleMintsAccumulate() public {
        (externalEuint64 enc1, bytes memory p1) = encryptUint64(300, address(pet));
        (externalEuint64 enc2, bytes memory p2) = encryptUint64(500, address(pet));
        pet.mint(alice, FHE.fromExternal(enc1, p1));
        pet.mint(alice, FHE.fromExternal(enc2, p2));

        uint256 aliceBal = decrypt(euint64.unwrap(pet.getEncryptedBalance(alice)));
        assertEq(aliceBal, 800, "alice balance should be 800 after two mints");

        uint256 totalSupply = decrypt(euint64.unwrap(pet.getTotalEncryptedSupply()));
        assertEq(totalSupply, 800, "total supply should be 800");
    }

    // ========== HOOK TRANSFER ==========

    function testHookTransferMovesBalanceBetweenUsers() public {
        uint64 mintAmount = 500;
        (externalEuint64 encMint, bytes memory proof) = encryptUint64(mintAmount, address(pet));
        pet.mint(alice, FHE.fromExternal(encMint, proof));

        uint64 transferAmount = 300;
        (externalEuint64 encTransfer, bytes memory transferProof) = encryptUint64(transferAmount, address(pet));
        pet.hookTransfer(alice, bob, FHE.fromExternal(encTransfer, transferProof));

        uint256 aliceBal = decrypt(euint64.unwrap(pet.getEncryptedBalance(alice)));
        assertEq(aliceBal, mintAmount - transferAmount, "alice balance should decrease");

        uint256 bobBal = decrypt(euint64.unwrap(pet.getEncryptedBalance(bob)));
        assertEq(bobBal, transferAmount, "bob balance should equal transfer amount");
    }

    function testHookTransferClampsToBalance() public {
        // Mint 200 to alice
        (externalEuint64 encMint, bytes memory proof) = encryptUint64(200, address(pet));
        pet.mint(alice, FHE.fromExternal(encMint, proof));

        // Try to transfer 500 (more than balance)
        (externalEuint64 encTransfer, bytes memory transferProof) = encryptUint64(500, address(pet));
        pet.hookTransfer(alice, bob, FHE.fromExternal(encTransfer, transferProof));

        // bob should receive at most alice's original balance
        uint256 bobBal = decrypt(euint64.unwrap(pet.getEncryptedBalance(bob)));
        assertEq(bobBal, 200, "bob receives at most alice's balance (200), not 500");

        // alice should have 0
        uint256 aliceBal = decrypt(euint64.unwrap(pet.getEncryptedBalance(alice)));
        assertEq(aliceBal, 0, "alice should have 0 after over-transfer");
    }

    function testHookTransferZeroAmount() public {
        (externalEuint64 encMint, bytes memory proof) = encryptUint64(500, address(pet));
        pet.mint(alice, FHE.fromExternal(encMint, proof));
        (externalEuint64 encZero, bytes memory zeroProof) = encryptUint64(0, address(pet));
        pet.hookTransfer(alice, bob, FHE.fromExternal(encZero, zeroProof));

        uint256 aliceBal = decrypt(euint64.unwrap(pet.getEncryptedBalance(alice)));
        assertEq(aliceBal, 500, "alice balance unchanged after zero transfer");

        uint256 bobBal = decrypt(euint64.unwrap(pet.getEncryptedBalance(bob)));
        assertEq(bobBal, 0, "bob balance still 0");
    }

    function testHookTransferToSelf() public {
        (externalEuint64 encMint, bytes memory proof) = encryptUint64(500, address(pet));
        pet.mint(alice, FHE.fromExternal(encMint, proof));
        (externalEuint64 encTransfer, bytes memory transferProof) = encryptUint64(200, address(pet));
        pet.hookTransfer(alice, alice, FHE.fromExternal(encTransfer, transferProof));

        uint256 aliceBal = decrypt(euint64.unwrap(pet.getEncryptedBalance(alice)));
        assertEq(aliceBal, 500, "alice balance unchanged after self-transfer");
    }

    // ========== ACCESS CONTROL ==========

    function testMintOnlyCallableByHook() public {
        (externalEuint64 encAmount, bytes memory proof) = encryptUint64(100, address(pet));
        vm.prank(alice);
        vm.expectRevert(PoolEncryptedToken.OnlyHook.selector);
        pet.mint(alice, FHE.fromExternal(encAmount, proof));
    }

    function testBurnOnlyCallableByHook() public {
        (externalEuint64 encMint, bytes memory proof) = encryptUint64(100, address(pet));
        pet.mint(alice, FHE.fromExternal(encMint, proof));
        (externalEuint64 encBurn, bytes memory burnProof) = encryptUint64(50, address(pet));
        vm.prank(alice);
        vm.expectRevert(PoolEncryptedToken.OnlyHook.selector);
        pet.burn(alice, FHE.fromExternal(encBurn, burnProof));
    }

    function testHookTransferOnlyCallableByHook() public {
        (externalEuint64 encMint, bytes memory proof) = encryptUint64(100, address(pet));
        pet.mint(alice, FHE.fromExternal(encMint, proof));
        (externalEuint64 encTransfer, bytes memory transferProof) = encryptUint64(100, address(pet));
        vm.prank(alice);
        vm.expectRevert(PoolEncryptedToken.OnlyHook.selector);
        pet.hookTransfer(alice, bob, FHE.fromExternal(encTransfer, transferProof));
    }
}

// ========== INTERNAL TRANSFER TESTS ==========

contract InternalTransferTest is FhevmTest {
    using PoolIdLibrary for PoolKey;

    TestPoolManagerIntegration public poolManager;
    TestablePrivateLiquidityTrackerZama public tracker;
    address public alice;
    address public bob;
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        poolManager = new TestPoolManagerIntegration();
        tracker = poolManager.hook();

        MockERC20Integration token0 = new MockERC20Integration();
        MockERC20Integration token1 = new MockERC20Integration();

        (Currency currency0, Currency currency1) = _sortTokens(address(token0), address(token1));
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(tracker)
        });
        poolId = poolKey.toId();

        // Initialize pool (creates PoolEncryptedToken)
        poolManager.callAfterInitialize(tracker, alice, poolKey, SQRT_PRICE, 0);

        vm.label(alice, "alice");
        vm.label(bob, "bob");
    }

    uint160 internal constant SQRT_PRICE = 79228162514264337593543950336;

    function _sortTokens(address tokenA, address tokenB) internal pure returns (Currency, Currency) {
        if (tokenA < tokenB) {
            return (Currency.wrap(tokenA), Currency.wrap(tokenB));
        }
        return (Currency.wrap(tokenB), Currency.wrap(tokenA));
    }

    // ========== MINT INTERNAL TRANSFER TOKEN ==========

    function testMintInternalTransferToken_FHEVerification() public {
        uint64 mintAmt = 500;

        // Mint internal transfer token to alice
        tracker.mintInternalTransferToken(poolKey, alice, mintAmt);

        // Decrypt and verify alice's pool token balance
        euint64 aliceBal = tracker.getEncryptedPoolTokenBalance(poolKey, alice);
        uint256 clearBal = decrypt(euint64.unwrap(aliceBal));
        assertEq(clearBal, mintAmt, "alice pool token balance should equal mint amount");
    }

    // ========== EXECUTE INTERNAL TRANSFER ==========

    function testExecuteInternalTransfer_FHEVerification() public {
        // Arrange - mint internal transfer tokens to alice
        tracker.mintInternalTransferToken(poolKey, alice, 1000);

        // Act - transfer 400 from alice to bob
        tracker.executeInternalTransfer(poolKey, alice, bob, 400);

        // Assert alice - should have 600 remaining
        uint256 aliceBal = decrypt(euint64.unwrap(tracker.getEncryptedPoolTokenBalance(poolKey, alice)));
        assertEq(aliceBal, 600, "alice should have 600 after transfer");

        // Assert bob - should have 400 received
        uint256 bobBal = decrypt(euint64.unwrap(tracker.getEncryptedPoolTokenBalance(poolKey, bob)));
        assertEq(bobBal, 400, "bob should have received 400");
    }

    function testExecuteInternalTransferClampsToBalance() public {
        // Mint only 200 to alice
        tracker.mintInternalTransferToken(poolKey, alice, 200);

        // Try to transfer 500
        tracker.executeInternalTransfer(poolKey, alice, bob, 500);

        // bob should receive at most 200
        uint256 bobBal = decrypt(euint64.unwrap(tracker.getEncryptedPoolTokenBalance(poolKey, bob)));
        assertEq(bobBal, 200, "bob receives at most alice's balance");
    }

    // ========== BURN INTERNAL TRANSFER TOKEN ==========

    function testBurnInternalTransferToken_FHEVerification() public {
        // Arrange
        tracker.mintInternalTransferToken(poolKey, alice, 1000);

        // Act - burn 300
        tracker.burnInternalTransferToken(poolKey, alice, 300);

        // Assert
        uint256 aliceBal = decrypt(euint64.unwrap(tracker.getEncryptedPoolTokenBalance(poolKey, alice)));
        assertEq(aliceBal, 700, "alice should have 700 after burning 300");
    }

    // ========== REVERTS ==========

    function testExecuteInternalTransferToZeroAddress_Reverts() public {
        tracker.mintInternalTransferToken(poolKey, alice, 1000);

        vm.expectRevert(PrivateLiquidityTrackerZama.InvalidReceiver.selector);
        tracker.executeInternalTransfer(poolKey, alice, address(0), 100);
    }

    function testExecuteInternalTransferZeroAmount_Reverts() public {
        tracker.mintInternalTransferToken(poolKey, alice, 1000);

        vm.expectRevert(PrivateLiquidityTrackerZama.InvalidAmount.selector);
        tracker.executeInternalTransfer(poolKey, alice, bob, 0);
    }
}

// ========== END-TO-END FLOW TESTS ==========

contract EndToEndFlowTest is FhevmTest {
    using PoolIdLibrary for PoolKey;

    TestPoolManagerIntegration public poolManager;
    TestablePrivateLiquidityTrackerZama public tracker;
    address public alice;
    address public bob;
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        poolManager = new TestPoolManagerIntegration();
        tracker = poolManager.hook();

        MockERC20Integration token0 = new MockERC20Integration();
        MockERC20Integration token1 = new MockERC20Integration();

        (Currency currency0, Currency currency1) = _sortTokens(address(token0), address(token1));
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(tracker)
        });
        poolId = poolKey.toId();

        poolManager.callAfterInitialize(tracker, alice, poolKey, SQRT_PRICE, 0);

        vm.label(alice, "alice");
        vm.label(bob, "bob");
    }

    uint160 internal constant SQRT_PRICE = 79228162514264337593543950336;

    function _sortTokens(address tokenA, address tokenB) internal pure returns (Currency, Currency) {
        if (tokenA < tokenB) {
            return (Currency.wrap(tokenA), Currency.wrap(tokenB));
        }
        return (Currency.wrap(tokenB), Currency.wrap(tokenA));
    }

    function testFullFlow_AddLiquidityThenInternalTransfer() public {
        // 1. Add liquidity via hook callback - alice adds 1000000
        int256 liquidityDelta = 1000000;
        poolManager.callAddLiquidity(tracker, alice, poolKey, liquidityDelta, "");

        // 2. Verify alice's LP shares encrypted balance
        euint128 aliceShares = tracker.getEncryptedLPSharesExt(poolKey, alice);
        uint256 clearShares = decrypt(euint128.unwrap(aliceShares));
        assertEq(clearShares, uint256(liquidityDelta), "alice LP shares should equal liquidity delta");

        // 3. Mint internal transfer tokens to alice (simulating matched intent)
        tracker.mintInternalTransferToken(poolKey, alice, 500);

        // 4. Execute internal transfer to bob
        tracker.executeInternalTransfer(poolKey, alice, bob, 500);

        // 5. Verify bob received internal tokens
        uint256 bobBal = decrypt(euint64.unwrap(tracker.getEncryptedPoolTokenBalance(poolKey, bob)));
        assertEq(bobBal, 500, "bob received internal transfer tokens");

        // 6. Verify alice's internal token balance reduced to 0
        uint256 aliceBal = decrypt(euint64.unwrap(tracker.getEncryptedPoolTokenBalance(poolKey, alice)));
        assertEq(aliceBal, 0, "alice internal balance should be 0 after transfer");
    }

    function testWrapThenTransferEncryptedPosition() public {
        // 1. Alice wraps 1000 LP tokens
        vm.prank(alice);
        tracker.wrapLPTokens(poolKey, 1000);

        // 2. Verify alice's encrypted shares increased
        euint128 aliceShares = tracker.getEncryptedLPSharesExt(poolKey, alice);
        uint256 clearShares = decrypt(euint128.unwrap(aliceShares));
        assertEq(clearShares, 1000, "alice shares should be 1000 after wrap");

        // 3. Transfer encrypted position to bob (400)
        vm.prank(alice);
        tracker.transferEncryptedPosition(poolKey, alice, bob, 400);

        // 4. Verify alice's shares decreased
        uint256 aliceRemaining = decrypt(euint128.unwrap(tracker.getEncryptedLPSharesExt(poolKey, alice)));
        assertEq(aliceRemaining, 600, "alice should have 600 after transfer");

        // 5. Verify bob's shares increased
        uint256 bobShares = decrypt(euint128.unwrap(tracker.getEncryptedLPSharesExt(poolKey, bob)));
        assertEq(bobShares, 400, "bob should have 400");
    }

    function testRemoveLiquidityUpdatesEncryptedShares() public {
        // Arrange - alice adds 1000000 liquidity
        poolManager.callAddLiquidity(tracker, alice, poolKey, 1000000, "");

        euint128 aliceSharesBefore = tracker.getEncryptedLPSharesExt(poolKey, alice);
        uint256 clearBefore = decrypt(euint128.unwrap(aliceSharesBefore));
        assertEq(clearBefore, 1000000, "alice should have 1M shares before removal");

        // Act - remove 400000
        poolManager.callRemoveLiquidity(tracker, alice, poolKey, -400000, "");

        // Assert - should have 600000 remaining
        uint256 clearAfter = decrypt(euint128.unwrap(tracker.getEncryptedLPSharesExt(poolKey, alice)));
        assertEq(clearAfter, 600000, "alice should have 600000 after removing 400000");
    }
}

// ========== FEE TRACKING TESTS ==========

contract FeeTrackingTest is FhevmTest {
    using PoolIdLibrary for PoolKey;

    TestPoolManagerIntegration public poolManager;
    TestablePrivateLiquidityTrackerZama public tracker;
    address public alice;
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");

        poolManager = new TestPoolManagerIntegration();
        tracker = poolManager.hook();

        MockERC20Integration token0 = new MockERC20Integration();
        MockERC20Integration token1 = new MockERC20Integration();

        (Currency currency0, Currency currency1) = _sortTokens(address(token0), address(token1));
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(tracker)
        });
        poolId = poolKey.toId();

        poolManager.callAfterInitialize(tracker, alice, poolKey, SQRT_PRICE, 0);

        vm.label(alice, "alice");
    }

    uint160 internal constant SQRT_PRICE = 79228162514264337593543950336;

    function _sortTokens(address tokenA, address tokenB) internal pure returns (Currency, Currency) {
        if (tokenA < tokenB) {
            return (Currency.wrap(tokenA), Currency.wrap(tokenB));
        }
        return (Currency.wrap(tokenB), Currency.wrap(tokenA));
    }

    function testFeeAccumulator_AfterAddLiquidityWithFees() public {
        // Act - add liquidity with fees accrued
        int128 feeAmount0 = 150;
        poolManager.callAddLiquidityWithFees(tracker, alice, poolKey, 1000000, feeAmount0, 0, "");

        // Get encrypted fees
        euint128 fees0 = tracker.getFeeAccumulator0(poolId);

        // Decrypt and verify
        uint256 clearFees0 = decrypt(euint128.unwrap(fees0));
        assertEq(clearFees0, uint128(feeAmount0), "fee accumulator 0 should track fees");
    }

    function testFeeAccumulator_MultipleAdds() public {
        // Add liquidity with 100 fees
        poolManager.callAddLiquidityWithFees(tracker, alice, poolKey, 1000000, 100, 0, "");

        // Add more liquidity with 50 fees
        poolManager.callAddLiquidityWithFees(tracker, alice, poolKey, 500000, 50, 0, "");

        // Total should be 150
        uint256 clearFees0 = decrypt(euint128.unwrap(tracker.getFeeAccumulator0(poolId)));
        assertEq(clearFees0, 150, "fee accumulator should accumulate fees");
    }
}

// ========== SUBSCRIBER CALLBACK TESTS ==========

contract SubscriberCallbackTest is FhevmTest {
    using PoolIdLibrary for PoolKey;

    TestPoolManagerIntegration public poolManager;
    TestablePrivateLiquidityTrackerZama public tracker;
    PrivateLiquidityTrackerZamaSubscriber public subscriber;
    address public alice;
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");

        poolManager = new TestPoolManagerIntegration();
        tracker = poolManager.hook();
        subscriber = new PrivateLiquidityTrackerZamaSubscriber(address(tracker));

        MockERC20Integration token0 = new MockERC20Integration();
        MockERC20Integration token1 = new MockERC20Integration();

        (Currency currency0, Currency currency1) = _sortTokens(address(token0), address(token1));
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(tracker)
        });
        poolId = poolKey.toId();

        poolManager.callAfterInitialize(tracker, alice, poolKey, SQRT_PRICE, 0);

        vm.label(alice, "alice");
    }

    uint160 internal constant SQRT_PRICE = 79228162514264337593543950336;

    function _sortTokens(address tokenA, address tokenB) internal pure returns (Currency, Currency) {
        if (tokenA < tokenB) {
            return (Currency.wrap(tokenA), Currency.wrap(tokenB));
        }
        return (Currency.wrap(tokenB), Currency.wrap(tokenA));
    }

    function testSubscriber_NotifySubscribe_SetsInitialShares() public {
        // Act - call notifySubscribe (pranked as tracker)
        vm.prank(address(tracker));
        subscriber.notifySubscribe(42, "");

        // Assert - encrypted shares should be tokenId (42)
        euint128 shares = subscriber.getEncryptedPositionShares(42);
        uint256 clearShares = decrypt(euint128.unwrap(shares));
        assertEq(clearShares, 42, "initial shares should equal tokenId");
    }

    function testSubscriber_NotifyModifyLiquidity_IncreasesShares() public {
        // Arrange - subscribe first
        vm.prank(address(tracker));
        subscriber.notifySubscribe(100, "");

        // Act - increase liquidity by 500
        vm.prank(address(tracker));
        subscriber.notifyModifyLiquidity(100, 500, BalanceDelta.wrap(0));

        // Assert - initial 100 + 500 = 600
        uint256 clearShares = decrypt(euint128.unwrap(subscriber.getEncryptedPositionShares(100)));
        assertEq(clearShares, 600, "shares should increase by liquidity change");
    }

    function testSubscriber_NotifyModifyLiquidity_DecreasesShares() public {
        // Arrange - subscribe first
        vm.prank(address(tracker));
        subscriber.notifySubscribe(100, "");

        // Act - decrease liquidity by 30
        vm.prank(address(tracker));
        subscriber.notifyModifyLiquidity(100, -30, BalanceDelta.wrap(0));

        // Assert - 100 - 30 = 70
        uint256 clearShares = decrypt(euint128.unwrap(subscriber.getEncryptedPositionShares(100)));
        assertEq(clearShares, 70, "shares should decrease by liquidity change");
    }

    function testSubscriber_NotifyBurn_ClearsShares() public {
        // Arrange - subscribe first
        vm.prank(address(tracker));
        subscriber.notifySubscribe(999, "");

        // Act - burn position
        vm.prank(address(tracker));
        subscriber.notifyBurn(999, alice, PositionInfo.wrap(0), 0, BalanceDelta.wrap(0));

        // Assert - shares should be 0
        uint256 clearShares = decrypt(euint128.unwrap(subscriber.getEncryptedPositionShares(999)));
        assertEq(clearShares, 0, "shares should be cleared after burn");
    }

    function testSubscriber_OnlyTrackerCanCall() public {
        vm.prank(alice);
        vm.expectRevert(PrivateLiquidityTrackerZamaSubscriber.OnlyTracker.selector);
        subscriber.notifySubscribe(1, "");
    }
}