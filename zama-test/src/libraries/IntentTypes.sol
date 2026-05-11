// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IntentTypes
/// @notice Minimal structs for LP intent support
/// @dev Provides basic intent and batch structures for private LP positions
library IntentTypes {
    // ========== ACTION TYPES ==========

    uint8 public constant ACTION_SWAP_0_TO_1 = 0;
    uint8 public constant ACTION_SWAP_1_TO_0 = 1;
    uint8 public constant ACTION_ADD_LIQUIDITY = 2;
    uint8 public constant ACTION_REMOVE_LIQUIDITY = 3;

    // ========== STRUCTS ==========

    /// @notice Represents an encrypted LP intent
    /// @dev Used for private position tracking with encrypted amounts
    struct LPIntent {
        address owner;
        bytes32 poolId;
        uint256 tokenId;
        uint64 deadline;
        bool processed;
    }

    /// @notice Batch of LP intents for processing
    struct LPBatch {
        bytes32[] intentIds;
        bytes32 poolId;
        bool finalized;
        uint64 counter;
        uint256 totalIntents;
    }

    /// @notice Pool reserve tracking
    struct PoolReserves {
        uint256 currency0Reserve;
        uint256 currency1Reserve;
        uint256 totalDeposits;
        uint256 totalWithdrawals;
    }

    /// @notice Internal transfer between matched positions
    struct InternalTransfer {
        address from;
        address to;
        uint256 tokenId;
        uint128 amount;
    }
}