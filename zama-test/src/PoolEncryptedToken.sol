// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title PoolEncryptedToken
/// @notice ERC7984-style confidential token for internal transfers between matched positions
/// @dev Allows the hook to mint/burn and execute internal transfers without touching AMM
contract PoolEncryptedToken {
    address public immutable hook;
    address public immutable underlying;
    bytes32 public immutable poolId;

    mapping(address => euint64) public encryptedBalances;

    euint64 private _totalEncSupply;

    error OnlyHook();
    error InsufficientBalance();

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor(address _hook, address _underlying, bytes32 _poolId) {
        hook = _hook;
        underlying = _underlying;
        poolId = _poolId;
        // Note: FHE operations not available in constructor
        // Call initialize() after deployment to set up FHE state
    }

    function initialize() external {
        FHE.setCoprocessor(ZamaConfig.getEthereumCoprocessorConfig());
        euint64 zero = FHE.asEuint64(0);
        _totalEncSupply = zero;
        FHE.allowThis(zero);
    }

    function mint(address to, euint64 amount) external onlyHook {
        encryptedBalances[to] = FHE.add(encryptedBalances[to], amount);
        _totalEncSupply = FHE.add(_totalEncSupply, amount);
        FHE.allowThis(encryptedBalances[to]);
        FHE.allow(encryptedBalances[to], to);
    }

    function burn(address from, euint64 amount) external onlyHook {
        euint64 currentBalance = encryptedBalances[from];
        euint64 amountToBurn = FHE.select(FHE.gt(amount, currentBalance), currentBalance, amount);
        encryptedBalances[from] = FHE.sub(encryptedBalances[from], amountToBurn);
        _totalEncSupply = FHE.sub(_totalEncSupply, amountToBurn);
        FHE.allowThis(encryptedBalances[from]);
    }

    /// @notice Internal transfer for matched intents - bypasses AMM
    function hookTransfer(address from, address to, euint64 amount) external onlyHook {
        euint64 fromBalance = encryptedBalances[from];
        euint64 amountToTransfer = FHE.select(FHE.gt(amount, fromBalance), fromBalance, amount);

        encryptedBalances[from] = FHE.sub(fromBalance, amountToTransfer);
        encryptedBalances[to] = FHE.add(encryptedBalances[to], amountToTransfer);

        FHE.allowThis(encryptedBalances[from]);
        FHE.allowThis(encryptedBalances[to]);
    }

    function getEncryptedBalance(address user) external view returns (euint64) {
        return encryptedBalances[user];
    }

    function getTotalEncryptedSupply() external view returns (euint64) {
        return _totalEncSupply;
    }
}
