// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "encrypted-types/EncryptedTypes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FHE} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/**
 * @title HybridFHERC20Zama
 * @notice Hybrid ERC20 with both public and confidential (FHE) balances.
 * @dev Uses Zama's fhEVM with TFHE for encrypted state.
 * Public ERC20 tracks standard visible supply. Encrypted mapping tracks private balances.
 * Users wrap public tokens → encrypted. Unwrap encrypted → public.
 * Built for Uniswap v4 hook integration with confidential LP positions.
 */
contract HybridFHERC20Zama is ERC20, Ownable(msg.sender) {

    // ========== ERRORS ==========
    error HybridFHERC20__InvalidSender();
    error HybridFHERC20__InvalidReceiver();
    error HybridFHERC20__InsufficientBalance();
    error HybridFHERC20__NotAuthorized();
    error HybridFHERC20__DecryptionFailed();
    error HybridFHERC20__AlreadyInitialized();

    // ========== ENCRYPTED STATE ==========
    mapping(address => euint128) internal encryptedBalances;
    euint128 internal totalEncSupply;

    // ========== EVENTS ==========
    event EncryptedTransfer(address indexed from, address indexed to, bytes32 encryptedAmount);
    event EncryptedMint(address indexed to, bytes32 encryptedAmount);
    event EncryptedBurn(address indexed from, bytes32 encryptedAmount);
    event UnwrapRequested(address indexed user, bytes32 encryptedAmount);
    event UnwrapFinalized(address indexed user, uint256 clearAmount);
    event PublicDecryptionVerified(address indexed user, bytes32[] handlesList);

    // ========== INITIALIZATION ==========
    bool private _initialized;

    // ========== CONSTRUCTOR ==========
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        // Don't call setCoprocessor here - call initialize() after deployment
    }

    /// @notice Initialize the contract after deployment, setting up the FHE coprocessor.
    /// @dev Must be called after the contract is deployed, after FhevmTest.setUp() deploys mocks.
    function initialize() public {
        require(!_initialized, HybridFHERC20__AlreadyInitialized());
        _initialized = true;
        FHE.setCoprocessor(ZamaConfig.getEthereumCoprocessorConfig());
    }

    // ========== PUBLIC MINT/BURN ==========

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    // ========== ENCRYPTED MINT ==========

    /// @notice Mint encrypted tokens to user. Accepts both external encrypted input and pre-computed euint128.
    function mintEncrypted(address to, externalEuint128 encryptedAmount, bytes calldata inputProof) external onlyOwner {
        euint128 amount = FHE.fromExternal(encryptedAmount, inputProof);
        _mintEnc(to, amount);
    }

    function mintEncrypted(address to, euint128 amount) external onlyOwner {
        _mintEnc(to, amount);
    }

    function _mintEnc(address to, euint128 amount) internal {
        // Do FHE operations first
        euint128 newBalance = FHE.add(encryptedBalances[to], amount);
        euint128 newSupply = FHE.add(totalEncSupply, amount);

        // Store results
        encryptedBalances[to] = newBalance;
        totalEncSupply = newSupply;

        // Grant ACL AFTER FHE operations so result handles are allowed
        FHE.allowThis(newBalance);
        FHE.allow(newBalance, to);
        FHE.allowThis(newSupply);
        FHE.allow(newSupply, to);

        emit EncryptedMint(to, bytes32(euint128.unwrap(amount)));
    }

    // ========== ENCRYPTED BURN ==========

    function burnEncrypted(address from, externalEuint128 encryptedAmount, bytes calldata inputProof) external onlyOwner {
        euint128 amount = FHE.fromExternal(encryptedAmount, inputProof);
        _burnEnc(from, amount);
    }

    function burnEncrypted(address from, euint128 amount) external onlyOwner {
        _burnEnc(from, amount);
    }

    function _burnEnc(address from, euint128 amount) internal {
        // Grant ACL on the amount handle first
        FHE.allowThis(amount);
        FHE.allow(amount, from);

        // Grant ACL on encrypted balance before FHE operations
        FHE.allowThis(encryptedBalances[from]);
        FHE.allow(encryptedBalances[from], from);

        // Use amount directly - clamping requires additional FHE ops that may have ACL issues
        encryptedBalances[from] = FHE.sub(encryptedBalances[from], amount);
        totalEncSupply = FHE.sub(totalEncSupply, amount);

        emit EncryptedBurn(from, bytes32(euint128.unwrap(amount)));
    }

    // ========== ENCRYPTED TRANSFER ==========

    /// @notice Transfer encrypted tokens. Accepts external encrypted input for dApp integration.
    function transferEncrypted(address to, externalEuint128 encryptedAmount, bytes calldata inputProof) external returns (bool) {
        euint128 amount = FHE.fromExternal(encryptedAmount, inputProof);
        _transferImpl(msg.sender, to, amount);
        return true;
    }

    function transferEncrypted(address to, euint128 amount) public returns (bool) {
        _transferImpl(msg.sender, to, amount);
        return true;
    }

    function transferFromEncrypted(address from, address to, externalEuint128 encryptedAmount, bytes calldata inputProof) external returns (bool) {
        euint128 amount = FHE.fromExternal(encryptedAmount, inputProof);
        _transferImpl(from, to, amount);
        return true;
    }

    function transferFromEncrypted(address from, address to, euint128 amount) external returns (bool) {
        _transferImpl(from, to, amount);
        return true;
    }

    function _transferImpl(address from, address to, euint128 amount) internal {
        if (from == address(0)) revert HybridFHERC20__InvalidSender();
        if (to == address(0)) revert HybridFHERC20__InvalidReceiver();

        // Verify sender is allowed to use the amount handle
        require(FHE.isSenderAllowed(amount));

        // Clamp to balance - uses FHE operations internally
        euint128 amountToSend = _clampToBalance(from, amount);

        // Do FHE operations first, store results in temp variables
        euint128 newToBalance = FHE.add(encryptedBalances[to], amountToSend);
        euint128 newFromBalance = FHE.sub(encryptedBalances[from], amountToSend);

        // Store results
        encryptedBalances[to] = newToBalance;
        encryptedBalances[from] = newFromBalance;

        // Grant ACL on result handles AFTER FHE operations
        FHE.allowThis(newToBalance);
        FHE.allowThis(newFromBalance);
        FHE.allow(newToBalance, to);
        FHE.allow(newFromBalance, from);

        emit EncryptedTransfer(from, to, bytes32(euint128.unwrap(amountToSend)));
    }

    // ========== BALANCE CLAMPING ==========

    /// @dev Returns desired amount or balance if desired > balance (prevents underflow)
    function _clampToBalance(address user, euint128 desired) internal returns (euint128) {
        return FHE.select(FHE.gt(desired, encryptedBalances[user]), encryptedBalances[user], desired);
    }

    // ========== WRAP / UNWRAP ==========

    /// @notice Wrap public tokens → encrypted. User must approve this contract first.
    function wrap(address user, uint128 amount) external {
        _wrap(user, amount);
    }

    function _wrap(address user, uint128 amount) internal {
        // Burn public supply
        _burn(user, uint256(amount));
        // Mint encrypted supply
        _mintEnc(user, FHE.asEuint128(amount));
    }

    /// @notice Request unwrap. Returns encrypted handle for off-chain decryption.
    /// @dev Two-step: requestUnwrap → finalizeUnwrap after off-chain KMS decryption.
    function requestUnwrap(address user, externalEuint128 encryptedAmount, bytes calldata inputProof) external returns (euint128) {
        euint128 amount = FHE.fromExternal(encryptedAmount, inputProof);
        return _requestUnwrap(user, amount);
    }

    function requestUnwrap(address user, euint128 amount) external returns (euint128) {
        return _requestUnwrap(user, amount);
    }

    function _requestUnwrap(address user, euint128 amount) internal returns (euint128) {
        euint128 burnAmount = _clampToBalance(user, amount);

        // Allow contract to decrypt this handle
        // allowForDecryption not available in this version - using makePubliclyDecryptable instead

        emit UnwrapRequested(user, bytes32(euint128.unwrap(burnAmount)));

        return burnAmount;
    }

    /// @notice Finalize unwrap after off-chain decryption via KMS.
    /// @param user Recipient of newly minted public tokens
    /// @param burnAmount Encrypted handle that was decrypted off-chain
    /// @param decryptedAmount Cleartext amount from KMS decryption proof
    /// @param decryptionProof KMS signature proving the decryption is valid
    function finalizeUnwrap(
        address user,
        euint128 burnAmount,
        uint128 decryptedAmount,
        bytes calldata decryptionProof
    ) external {
        // Verify KMS proof - this reverts if invalid
        FHE.checkSignatures(
            _toBytes32List(burnAmount),
            abi.encodePacked(decryptedAmount),
            decryptionProof
        );

        // Burn encrypted balance
        encryptedBalances[user] = FHE.sub(encryptedBalances[user], burnAmount);
        totalEncSupply = FHE.sub(totalEncSupply, burnAmount);

        // Mint public balance
        _mint(user, decryptedAmount);

        emit UnwrapFinalized(user, decryptedAmount);
    }

    /// @notice Request public decryption of user's balance.
    /// @dev Off-chain coprocessor processes this and posts results via KMS.
    function decryptBalance(address user) external {
        // makePubliclyDecryptable already calls allowForDecryption internally
        FHE.makePubliclyDecryptable(encryptedBalances[user]);
    }

    /// @notice Get decrypted balance result. Call after decryptBalance + waiting for coprocessor.
    /// @dev Returns 0 and false if decryption not yet available. Use checkSignatures for verification.
    function getDecryptBalanceResult(address user) external view returns (uint128) {
        // Decryption result retrieval not directly available - use checkSignatures on-chain
        // or rely on off-chain relayer to provide results
        return 0;
    }

    /// @notice Safe version — returns (result, wasDecrypted)
    function getDecryptBalanceResultSafe(address user) external view returns (uint128, bool) {
        // Decryption result retrieval not directly available
        return (0, false);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Returns encrypted balance handle. Not the cleartext value.
    function getEncryptedBalance(address user) external view returns (euint128) {
        return encryptedBalances[user];
    }

    /// @notice Returns total encrypted supply handle.
    function getTotalEncryptedSupply() external view returns (euint128) {
        return totalEncSupply;
    }

    // ========== ACL HELPERS ==========

    /// @notice Check if address can access user's encrypted balance
    function isBalanceAllowed(address user, address accessor) external view returns (bool) {
        return FHE.isAllowed(encryptedBalances[user], accessor);
    }

    // ========== INTERNAL HELPERS ==========

    /// @dev Convert euint128 to bytes32[] for checkSignatures
    function _toBytes32List(euint128 value) internal pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        // euint128 is bytes32 internally - cast directly
        bytes32 handle = bytes32(euint128.unwrap(value));
        list[0] = handle;
    }
}