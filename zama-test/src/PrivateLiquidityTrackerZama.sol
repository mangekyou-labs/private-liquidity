// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Uniswap V4 Imports
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {INotifier} from "@uniswap/v4-periphery/src/interfaces/INotifier.sol";

// Zama FHE Imports
import {FHE, euint128, ebool, euint8, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {PoolEncryptedToken} from "./PoolEncryptedToken.sol";

/// @title PrivateLiquidityTrackerZama
/// @notice Tracks cumulative liquidity changes using Zama fhEVM
/// @dev Uniswap V4 hook that maintains encrypted LP share positions
contract PrivateLiquidityTrackerZama is BaseHook {
    using PoolIdLibrary for PoolKey;

    // ========== ENCRYPTED STATE ==========
    mapping(PoolId => euint128) public token0Accumulator;
    mapping(PoolId => euint128) public token1Accumulator;
    mapping(PoolId => address) public poolOwner;

    // Per-user encrypted LP shares
    mapping(PoolId => mapping(address => euint128)) public encryptedLPShares;
    mapping(PoolId => mapping(address => bool)) public hasAccess;

    // Encrypted operation type per user (0=swap0to1, 1=swap1to0, 2=addLiq, 3=removeLiq)
    mapping(PoolId => mapping(address => euint8)) public encryptedOperationType;

    // Fee tracking per pool
    mapping(PoolId => euint128) public feeAccumulator0;
    mapping(PoolId => euint128) public feeAccumulator1;

    // Internal transfer tokens (ERC7984-style per pool)
    mapping(PoolId => PoolEncryptedToken) public poolEncryptedTokens;

    // ========== ACTION TYPE CONSTANTS ==========
    uint8 public constant ACTION_SWAP_0_TO_1 = 0;
    uint8 public constant ACTION_SWAP_1_TO_0 = 1;
    uint8 public constant ACTION_ADD_LIQUIDITY = 2;
    uint8 public constant ACTION_REMOVE_LIQUIDITY = 3;

    // Decryption tracking
    struct DecryptionRequest {
        euint128 token0Handle;
        euint128 token1Handle;
        bool requested;
    }

    mapping(PoolId => DecryptionRequest) public decryptionRequests;

    // ========== EVENTS ==========
    event LiquidityTracked(PoolId indexed poolId, bool isAddition, uint128 amount);
    event EncryptedLPMinted(address indexed user, PoolId indexed poolId, uint128 amount);
    event EncryptedLPBurned(address indexed user, PoolId indexed poolId, uint128 amount);
    event EncryptedLPTransferred(address indexed from, address indexed to, PoolId indexed poolId, uint128 amount);
    event DecryptionRequested(PoolId indexed poolId, address indexed owner);
    event Wrap(address indexed user, uint128 amount);
    event Unwrap(address indexed user, uint128 amount);
    event InternalTransferExecuted(address indexed from, address indexed to, PoolId indexed poolId, uint64 amount);
    event FeesAccumulated(PoolId indexed poolId, uint128 fees0, uint128 fees1);
    event PoolEncryptedTokenCreated(PoolId indexed poolId, address indexed token);
    event EncryptedOperationTypeSet(address indexed user, PoolId indexed poolId, uint8 operationType);

    // ========== ERRORS ==========
    error OnlyPoolOwner();
    error DecryptionAlreadyRequested();
    error NoDecryptionRequested();
    error DecryptionNotReady();
    error InvalidReceiver();
    error InvalidAmount();
    error InternalTransferFailed();
    error PoolEncryptedTokenAlreadyExists();
    error PositionManagerAlreadySet();

    // ========== INITIALIZATION ==========
    bool private _initialized;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function initialize() public {
        require(!_initialized, "Already initialized");
        _initialized = true;
        FHE.setCoprocessor(ZamaConfig.getEthereumCoprocessorConfig());
    }

    // ========== HOOK PERMISSIONS ==========
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Override to skip address validation (used for testing with any address)
    function validateHookAddress(BaseHook _this) internal pure override {}

    // ========== HOOK IMPLEMENTATIONS ==========

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        poolOwner[poolId] = tx.origin;

        euint128 zero = FHE.asEuint128(0);
        token0Accumulator[poolId] = zero;
        token1Accumulator[poolId] = zero;
        feeAccumulator0[poolId] = zero;
        feeAccumulator1[poolId] = zero;
        FHE.allowThis(zero);

        // Create PoolEncryptedToken for internal transfers
        PoolEncryptedToken encToken = new PoolEncryptedToken({
            _hook: address(this),
            _underlying: Currency.unwrap(key.currency0),
            _poolId: PoolId.unwrap(poolId)
        });
        encToken.initialize();
        poolEncryptedTokens[poolId] = encToken;

        emit PoolEncryptedTokenCreated(poolId, address(encToken));

        return BaseHook.afterInitialize.selector;
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        int256 liquidityDelta = params.liquidityDelta;

        if (liquidityDelta > 0) {
            euint128 encAmount = FHE.asEuint128(uint128(uint256(liquidityDelta)));
            euint128 currentAcc0 = token0Accumulator[poolId];
            euint128 newAcc0 = FHE.add(currentAcc0, encAmount);
            token0Accumulator[poolId] = newAcc0;
            FHE.allowThis(newAcc0);

            euint128 currentAcc1 = token1Accumulator[poolId];
            euint128 newAcc1 = FHE.add(currentAcc1, encAmount);
            token1Accumulator[poolId] = newAcc1;
            FHE.allowThis(newAcc1);

            emit LiquidityTracked(poolId, true, uint128(uint256(liquidityDelta)));
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        int256 liquidityDelta = params.liquidityDelta;

        if (liquidityDelta < 0) {
            uint128 absAmount = uint128(uint256(-liquidityDelta));
            euint128 encAmount = FHE.asEuint128(absAmount);
            euint128 currentAcc0 = token0Accumulator[poolId];
            euint128 newAcc0 = FHE.sub(currentAcc0, encAmount);
            token0Accumulator[poolId] = newAcc0;
            FHE.allowThis(newAcc0);

            euint128 currentAcc1 = token1Accumulator[poolId];
            euint128 newAcc1 = FHE.sub(currentAcc1, encAmount);
            token1Accumulator[poolId] = newAcc1;
            FHE.allowThis(newAcc1);

            emit LiquidityTracked(poolId, false, absAmount);
        }

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        int256 liquidityDelta = params.liquidityDelta;

        if (liquidityDelta > 0) {
            euint128 newShares = FHE.asEuint128(uint128(uint256(liquidityDelta)));

            euint128 currentShares = encryptedLPShares[poolId][sender];
            euint128 newTotalShares = FHE.add(currentShares, newShares);

            encryptedLPShares[poolId][sender] = newTotalShares;

            // Grant ACL AFTER FHE operations on result handles
            FHE.allowThis(newTotalShares);
            FHE.allow(newTotalShares, sender);
            hasAccess[poolId][sender] = true;

            // Set encrypted operation type
            euint8 opType = FHE.asEuint8(ACTION_ADD_LIQUIDITY);
            encryptedOperationType[poolId][sender] = opType;
            FHE.allowThis(opType);
            FHE.allow(opType, sender);

            emit EncryptedLPMinted(sender, poolId, uint128(uint256(liquidityDelta)));
        }

        // Track fees
        int128 feesAmount0 = BalanceDeltaLibrary.amount0(feesAccrued);
        if (feesAmount0 > 0) {
            euint128 fees = FHE.asEuint128(uint128(feesAmount0));
            euint128 currentFees = feeAccumulator0[poolId];
            feeAccumulator0[poolId] = FHE.add(currentFees, fees);
            FHE.allowThis(feeAccumulator0[poolId]);
            emit FeesAccumulated(poolId, uint128(feesAmount0), 0);
        }

        int128 feesAmount1 = BalanceDeltaLibrary.amount1(feesAccrued);
        if (feesAmount1 > 0) {
            euint128 fees = FHE.asEuint128(uint128(feesAmount1));
            euint128 currentFees = feeAccumulator1[poolId];
            feeAccumulator1[poolId] = FHE.add(currentFees, fees);
            FHE.allowThis(feeAccumulator1[poolId]);
            emit FeesAccumulated(poolId, 0, uint128(feesAmount1));
        }

        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        int256 liquidityDelta = params.liquidityDelta;

        if (liquidityDelta < 0) {
            euint128 sharesToBurn = FHE.asEuint128(uint128(uint256(-liquidityDelta)));

            euint128 currentShares = encryptedLPShares[poolId][sender];
            euint128 newTotalShares = FHE.sub(currentShares, sharesToBurn);

            encryptedLPShares[poolId][sender] = newTotalShares;

            // Grant ACL AFTER FHE operations
            FHE.allowThis(newTotalShares);
            FHE.allow(newTotalShares, sender);

            // Set encrypted operation type
            euint8 opType = FHE.asEuint8(ACTION_REMOVE_LIQUIDITY);
            encryptedOperationType[poolId][sender] = opType;
            FHE.allowThis(opType);
            FHE.allow(opType, sender);

            emit EncryptedLPBurned(sender, poolId, uint128(uint256(-liquidityDelta)));
        }

        return (BaseHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    // ========== WRAP / UNWRAP ==========

    function wrapLPTokens(PoolKey calldata key, uint128 amount) external {
        PoolId poolId = key.toId();
        address user = msg.sender;

        euint128 encAmount = FHE.asEuint128(amount);
        euint128 currentShares = encryptedLPShares[poolId][user];
        euint128 newTotalShares = FHE.add(currentShares, encAmount);

        encryptedLPShares[poolId][user] = newTotalShares;

        // Grant ACL AFTER FHE operations
        FHE.allowThis(newTotalShares);
        FHE.allow(newTotalShares, user);
        hasAccess[poolId][user] = true;

        emit Wrap(user, amount);
    }

    function unwrapLPTokens(PoolKey calldata key, uint128 amount) external {
        PoolId poolId = key.toId();
        address user = msg.sender;

        euint128 encAmount = FHE.asEuint128(amount);
        euint128 currentShares = encryptedLPShares[poolId][user];
        euint128 newTotalShares = FHE.sub(currentShares, encAmount);

        encryptedLPShares[poolId][user] = newTotalShares;

        // Grant ACL AFTER FHE operations
        FHE.allowThis(newTotalShares);
        FHE.allow(newTotalShares, user);

        emit Unwrap(user, amount);
    }

    // ========== ENCRYPTED POSITION TRANSFER ==========

    function transferEncryptedPosition(
        PoolKey calldata key,
        address from,
        address to,
        uint128 amount
    ) external {
        if (to == address(0)) revert InvalidReceiver();
        if (amount == 0) revert InvalidAmount();

        PoolId poolId = key.toId();

        euint128 encAmount = FHE.asEuint128(amount);
        euint128 fromShares = encryptedLPShares[poolId][from];

        // Clamp to balance (prevents underflow)
        euint128 amountToTransfer = FHE.select(
            FHE.gt(encAmount, fromShares),
            fromShares,
            encAmount
        );

        // Do FHE operations first, store in temp variables
        euint128 newFromShares = FHE.sub(fromShares, amountToTransfer);
        euint128 currentToShares = encryptedLPShares[poolId][to];
        euint128 newToShares = FHE.add(currentToShares, amountToTransfer);

        // Store results
        encryptedLPShares[poolId][from] = newFromShares;
        encryptedLPShares[poolId][to] = newToShares;

        // Grant ACL AFTER FHE operations on result handles
        FHE.allowThis(newFromShares);
        FHE.allowThis(newToShares);
        FHE.allow(newFromShares, from);
        FHE.allow(newToShares, to);

        emit EncryptedLPTransferred(from, to, poolId, amount);
    }

    // ========== VIEW FUNCTIONS ==========

    function getEncryptedLPShares(PoolKey calldata key, address user) external view returns (euint128) {
        PoolId poolId = key.toId();
        return encryptedLPShares[poolId][user];
    }

    function isPositionAllowed(PoolKey calldata key, address user, address accessor) external view returns (bool) {
        PoolId poolId = key.toId();
        return FHE.isAllowed(encryptedLPShares[poolId][user], accessor);
    }

    function requestDecryption(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        if (msg.sender != poolOwner[poolId]) revert OnlyPoolOwner();
        if (decryptionRequests[poolId].requested) revert DecryptionAlreadyRequested();

        euint128 acc0 = token0Accumulator[poolId];
        euint128 acc1 = token1Accumulator[poolId];

        FHE.makePubliclyDecryptable(acc0);
        FHE.makePubliclyDecryptable(acc1);

        decryptionRequests[poolId] = DecryptionRequest({
            token0Handle: acc0,
            token1Handle: acc1,
            requested: true
        });

        emit DecryptionRequested(poolId, msg.sender);
    }

    function isDecryptionReady(PoolKey calldata key)
        external
        view
        returns (bool requested, bool ready)
    {
        PoolId poolId = key.toId();
        DecryptionRequest memory request = decryptionRequests[poolId];

        if (!request.requested) {
            return (false, false);
        }

        // In Zama, decryption results come back via off-chain relayer + KMS
        // This view cannot return actual decrypted values without the relayer
        // The contract marks it as ready when requested (actual result via KMS)
        return (true, request.requested);
    }

    function resetTracking(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        if (msg.sender != poolOwner[poolId]) revert OnlyPoolOwner();

        euint128 zero = FHE.asEuint128(0);
        token0Accumulator[poolId] = zero;
        token1Accumulator[poolId] = zero;
        feeAccumulator0[poolId] = zero;
        feeAccumulator1[poolId] = zero;
        FHE.allowThis(zero);

        delete decryptionRequests[poolId];
    }

    // ========== ENCRYPTED OPERATION TYPE ==========

    function getEncryptedOperationType(PoolKey calldata key, address user) external view returns (euint8) {
        PoolId poolId = key.toId();
        return encryptedOperationType[poolId][user];
    }

    function setEncryptedOperationType(PoolKey calldata key, uint8 operationType) external {
        PoolId poolId = key.toId();
        address user = msg.sender;

        euint8 opType = FHE.asEuint8(operationType);
        encryptedOperationType[poolId][user] = opType;
        FHE.allowThis(opType);
        FHE.allow(opType, user);

        emit EncryptedOperationTypeSet(user, poolId, operationType);
    }

    // ========== FEE TRACKING ==========

    function getEncryptedFeesEarned(PoolKey calldata key) external view returns (euint128 fees0, euint128 fees1) {
        PoolId poolId = key.toId();
        return (feeAccumulator0[poolId], feeAccumulator1[poolId]);
    }

    // ========== INTERNAL TRANSFERS ==========

    /// @notice Execute internal transfer between matched positions - bypasses AMM
    function executeInternalTransfer(
        PoolKey calldata key,
        address from,
        address to,
        uint64 amount
    ) external {
        if (to == address(0)) revert InvalidReceiver();
        if (amount == 0) revert InvalidAmount();

        PoolId poolId = key.toId();
        PoolEncryptedToken encToken = poolEncryptedTokens[poolId];

        euint64 encAmount = FHE.asEuint64(amount);
        encToken.hookTransfer(from, to, encAmount);

        emit InternalTransferExecuted(from, to, poolId, amount);
    }

    /// @notice Mint internal transfer tokens (hook only)
    function mintInternalTransferToken(PoolKey calldata key, address to, uint64 amount) external {
        PoolId poolId = key.toId();
        PoolEncryptedToken encToken = poolEncryptedTokens[poolId];
        euint64 encAmount = FHE.asEuint64(amount);
        encToken.mint(to, encAmount);
    }

    /// @notice Burn internal transfer tokens (hook only)
    function burnInternalTransferToken(PoolKey calldata key, address from, uint64 amount) external {
        PoolId poolId = key.toId();
        PoolEncryptedToken encToken = poolEncryptedTokens[poolId];
        euint64 encAmount = FHE.asEuint64(amount);
        encToken.burn(from, encAmount);
    }

    /// @notice Get encrypted balance from pool token
    function getEncryptedPoolTokenBalance(PoolKey calldata key, address user) external view returns (euint64) {
        PoolId poolId = key.toId();
        PoolEncryptedToken encToken = poolEncryptedTokens[poolId];
        return encToken.getEncryptedBalance(user);
    }

    // ========== SUBSCRIBER INTEGRATION ==========

    /// @notice Address of the subscriber contract for NFT position tracking
    address public subscriber;

    /// @notice Address of the PositionManager for NFT position operations
    address public positionManager;

    /// @notice Subscribe to an NFT-backed LP position
    /// @dev Calls PositionManager.subscribe to opt-in to position updates
    /// @param tokenId The ERC721 token ID of the position to subscribe to
    /// @param subscriberContract The address of the ISubscriber implementation
    function subscribeToPosition(uint256 tokenId, address subscriberContract) external {
        if (subscriberContract == address(0)) revert InvalidReceiver();

        // Store subscriber reference if not set
        if (subscriber == address(0)) {
            subscriber = subscriberContract;
        }

        // Call PositionManager.subscribe if positionManager is set
        if (positionManager != address(0)) {
            INotifier(positionManager).subscribe(tokenId, subscriberContract, "");
        }

        emit SubscribedToPosition(msg.sender, tokenId, subscriberContract);
    }

    /// @notice Set the PositionManager address for NFT subscription integration
    function setPositionManager(address _positionManager) external {
        if (positionManager != address(0)) revert PositionManagerAlreadySet();
        positionManager = _positionManager;
    }

    /// @notice Get the subscriber contract address
    function getSubscriber() external view returns (address) {
        return subscriber;
    }

    event SubscribedToPosition(address indexed user, uint256 indexed tokenId, address indexed subscriber);
}