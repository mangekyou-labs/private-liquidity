// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FHE, euint128, ebool} from "@fhevm/solidity/lib/FHE.sol";

/// @title PrivateLiquidityTrackerZamaSubscriber
/// @notice ISubscriber implementation that tracks NFT-backed LP positions privately with FHE
/// @dev Position shares are stored as encrypted handles via Zama fhEVM
contract PrivateLiquidityTrackerZamaSubscriber is ISubscriber {

    // ========== STATE ==========

    /// @notice Link to main tracker contract
    address public immutable tracker;

    /// @notice NFT tokenId → encrypted LP shares (FHE encrypted)
    mapping(uint256 => euint128) internal encryptedPositionShares;

    /// @notice User → list of tokenIds they own (for enumeration)
    mapping(address => uint256[]) public userTokenIds;

    /// @notice NFT tokenId → poolId (from PositionInfo)
    mapping(uint256 => bytes32) public tokenPoolIds;

    // ========== EVENTS ==========

    event Subscribed(uint256 indexed tokenId, address indexed subscriber, address indexed owner);
    event Unsubscribed(uint256 indexed tokenId);
    event LiquidityModified(uint256 indexed tokenId, int256 liquidityChange, uint128 feesCollected);
    event PositionBurned(uint256 indexed tokenId, address indexed owner, uint256 liquidity, uint128 feesCollected);

    // ========== ERRORS ==========

    error OnlyTracker();
    error AlreadySubscribed();
    error NotSubscribed();
    error InvalidTokenId();

    // ========== MODIFIERS ==========

    modifier onlyTracker() {
        if (msg.sender != tracker) revert OnlyTracker();
        _;
    }

    // ========== CONSTRUCTOR ==========

    constructor(address _tracker) {
        if (_tracker == address(0)) revert InvalidTokenId();
        tracker = _tracker;
    }

    // ========== ISubscriber CALLBACKS ==========

    /// @notice Called when a position subscribes to this subscriber
    /// @dev msg.sender is the user who called PositionManager.subscribe (they approved/owned the position)
    function notifySubscribe(uint256 tokenId, bytes memory) external {
        address owner = msg.sender;

        // Initialize shares as encrypted tokenId (demonstration value)
        euint128 initialShares = FHE.asEuint128(uint128(tokenId));
        encryptedPositionShares[tokenId] = initialShares;
        FHE.allowThis(initialShares);
        FHE.allow(initialShares, address(this));

        // Track user's tokenIds
        userTokenIds[owner].push(tokenId);

        emit Subscribed(tokenId, address(this), owner);
    }

    /// @notice Called when a position unsubscribes
    /// @dev msg.sender is the user who unsubscribed
    function notifyUnsubscribe(uint256 tokenId) external {
        address user = msg.sender;

        // Clear encrypted state
        euint128 zero = FHE.asEuint128(0);
        encryptedPositionShares[tokenId] = zero;
        FHE.allowThis(zero);

        delete tokenPoolIds[tokenId];

        // Remove from user's tokenIds list (swap-with-last for gas efficiency)
        _removeTokenIdFromUser(user, tokenId);

        emit Unsubscribed(tokenId);
    }

    /// @notice Called when position liquidity changes or fees are collected
    function notifyModifyLiquidity(
        uint256 tokenId,
        int256 liquidityChange,
        BalanceDelta feesAccrued
    ) external {
        euint128 currentShares = encryptedPositionShares[tokenId];
        euint128 zero = FHE.asEuint128(0);
        // Check if subscribed using FHE.eq
        ebool isZero = FHE.eq(currentShares, zero);
        bool isZeroVal = ebool.unwrap(isZero) != 0;
        if (!isZeroVal) revert NotSubscribed();

        if (liquidityChange != 0) {
            uint128 absChange = liquidityChange > 0
                ? uint128(uint256(liquidityChange))
                : uint128(uint256(-liquidityChange));
            euint128 change = FHE.asEuint128(absChange);

            euint128 newShares;
            if (liquidityChange > 0) {
                newShares = FHE.add(currentShares, change);
            } else {
                newShares = FHE.sub(currentShares, change);
            }

            encryptedPositionShares[tokenId] = newShares;
            FHE.allowThis(newShares);
        }

        uint128 fees0 = uint128(BalanceDeltaLibrary.amount0(feesAccrued));
        uint128 fees1 = uint128(BalanceDeltaLibrary.amount1(feesAccrued));
        uint128 totalFees = fees0 + fees1;
        emit LiquidityModified(tokenId, liquidityChange, totalFees);
    }

    /// @notice Called when position is burned
    function notifyBurn(
        uint256 tokenId,
        address owner,
        PositionInfo,
        uint256,
        BalanceDelta
    ) external {
        euint128 zero = FHE.asEuint128(0);
        encryptedPositionShares[tokenId] = zero;
        FHE.allowThis(zero);

        delete tokenPoolIds[tokenId];
        _removeTokenIdFromUser(owner, tokenId);
    }

    // ========== HELPER FUNCTIONS ==========

    function _removeTokenIdFromUser(address user, uint256 tokenId) internal {
        uint256[] storage ids = userTokenIds[user];
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] == tokenId) {
                ids[i] = ids[len - 1];
                ids.pop();
                return;
            }
        }
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Returns encrypted position shares handle
    function getEncryptedPositionShares(uint256 tokenId) external view returns (euint128) {
        return encryptedPositionShares[tokenId];
    }

    /// @notice Check if position is subscribed
    /// @dev Note: FHE operations require non-view, cost gas
    function isSubscribed(uint256 tokenId) external returns (bool) {
        euint128 shares = encryptedPositionShares[tokenId];
        euint128 zero = FHE.asEuint128(0);
        ebool isZero = FHE.eq(shares, zero);
        bool isZeroVal = ebool.unwrap(isZero) != 0;
        return !isZeroVal || tokenId == 0;
    }

    function getUserTokenIds(address user) external view returns (uint256[] memory) {
        return userTokenIds[user];
    }
}