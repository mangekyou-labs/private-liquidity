// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {PrivateLiquidityTrackerZama} from "../src/PrivateLiquidityTrackerZama.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @title PoolManagerAddresses - PoolManager addresses by chain
library PoolManagerAddresses {
    function getPoolManagerByChainId(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) {
            return address(0x000000000004444c5dc75cB358380D2e3dE08A90);
        } else if (chainId == 11155111) {
            return address(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        } else if (chainId == 8453) {
            return address(0x498581fF718922c3f8e6A244956aF099B2652b2b);
        } else if (chainId == 10) {
            return address(0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3);
        } else if (chainId == 42161) {
            return address(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32);
        } else if (chainId == 137) {
            return address(0x67366782805870060151383F4BbFF9daB53e5cD6);
        } else {
            revert("Unsupported chainId");
        }
    }
}

/// @notice Deploy PrivateLiquidityTrackerZama hook at a valid Uniswap v4 hook address
/// @dev Uses CREATE2 deployer to mine an address with correct hook flags
///      Run: forge script script/DeployHook.s.sol --rpc-url <SEPOLIA_RPC> -vvv
contract DeployPrivateLiquidityTrackerZamaHook is Script {
    // CREATE2 deployer - Uniswap's pre-signed CREATE2 proxy
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);

        // Get PoolManager for Sepolia
        uint256 chainId = block.chainid;
        IPoolManager manager = IPoolManager(PoolManagerAddresses.getPoolManagerByChainId(chainId));

        console2.log("Deploying PrivateLiquidityTrackerZama hook");
        console2.log("Chain ID:", chainId);
        console2.log("PoolManager:", address(manager));

        // Our hook needs these permissions:
        // - afterInitialize (bit 12)
        // - beforeAddLiquidity (bit 11)
        // - afterAddLiquidity (bit 10)
        // - beforeRemoveLiquidity (bit 9)
        // - afterRemoveLiquidity (bit 8)
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        console2.log("Required flags:", flags);
        console2.log("AFTER_INITIALIZE_FLAG:", Hooks.AFTER_INITIALIZE_FLAG);
        console2.log("BEFORE_ADD_LIQUIDITY_FLAG:", Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        console2.log("AFTER_ADD_LIQUIDITY_FLAG:", Hooks.AFTER_ADD_LIQUIDITY_FLAG);
        console2.log("BEFORE_REMOVE_LIQUIDITY_FLAG:", Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        console2.log("AFTER_REMOVE_LIQUIDITY_FLAG:", Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);

        // Mine salt that produces address with correct hook bits
        bytes memory constructorArgs = abi.encode(address(manager));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(PrivateLiquidityTrackerZama).creationCode, constructorArgs);

        console2.log("Mined hook address:", hookAddress);

        // Deploy hook at mined address
        PrivateLiquidityTrackerZama tracker = new PrivateLiquidityTrackerZama{salt: salt}(manager);
        require(address(tracker) == hookAddress, "Hook address mismatch");

        console2.log("Deployed PrivateLiquidityTrackerZama at:", address(tracker));
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Initialize pool with this hook");
        console2.log("2. Call modifyLiquidity to trigger hook callbacks");
        console2.log("3. Verify encrypted LP shares via decrypt()");

        vm.stopBroadcast();
    }
}
