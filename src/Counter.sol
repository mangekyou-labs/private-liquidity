// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice Placeholder hook for script compilation. Replace with actual hook.
contract Counter is BaseHook {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeAddLiquidity = true;
        permissions.beforeRemoveLiquidity = true;
    }
}