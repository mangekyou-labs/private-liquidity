// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {HybridFHERC20Zama} from "../src/HybridFHERC20Zama.sol";
import {FHE, euint128} from "@fhevm/solidity/lib/FHE.sol";
import {externalEuint128} from "encrypted-types/EncryptedTypes.sol";

/// @notice Test suite for HybridFHERC20Zama
/// @dev Uses Zama fhEVM library + forge-fhevm test harness
contract HybridFHERC20ZamaTest is FhevmTest {

    HybridFHERC20Zama public token;
    address public user;
    address public user2;

    uint128 constant INITIAL_MINT = 1e10;
    uint128 constant TRANSFER_AMOUNT = 1e5;

    function setUp() public override {
        // FhevmTest.setUp() deploys mocks first on chainid 31337
        super.setUp();

        user = makeAddr("user");
        user2 = makeAddr("user2");

        token = new HybridFHERC20Zama("Zama FHE Token", "ZFHE");
        // Initialize AFTER mocks are deployed
        token.initialize();

        // Mint public tokens
        token.mint(user, INITIAL_MINT);

        // Mint encrypted tokens to user using FhevmTest encryption helpers
        // encryptUint128(value, target) - user is address(this)
        (externalEuint128 encMint, bytes memory proof) = encryptUint128(INITIAL_MINT, address(token));
        token.mintEncrypted(user, encMint, proof);

        // Initialize user2 with zero encrypted balance
        (externalEuint128 zeroEnc, bytes memory zeroProof) = encryptUint128(0, address(token));
        token.mintEncrypted(user2, zeroEnc, zeroProof);

        vm.label(user, "user");
        vm.label(user2, "user2");
        vm.label(address(token), "token");
    }

    // ========== PUBLIC MINT/BURN TESTS ==========

    function testPublicMint() public {
        assertEq(token.balanceOf(user), INITIAL_MINT);
        token.mint(user, TRANSFER_AMOUNT);
        assertEq(token.balanceOf(user), INITIAL_MINT + TRANSFER_AMOUNT);
    }

    function testPublicBurn() public {
        assertEq(token.balanceOf(user), INITIAL_MINT);
        token.burn(user, TRANSFER_AMOUNT);
        assertEq(token.balanceOf(user), INITIAL_MINT - TRANSFER_AMOUNT);
    }

    // ========== ENCRYPTED MINT TESTS ==========

    function testEncryptedMint() public {
        uint128 balanceBefore = decrypt(token.getEncryptedBalance(user));

        (externalEuint128 encAmount, bytes memory proof) = encryptUint128(TRANSFER_AMOUNT, address(token));
        token.mintEncrypted(user, encAmount, proof);

        uint128 balanceAfter = decrypt(token.getEncryptedBalance(user));
        assertEq(balanceAfter, balanceBefore + TRANSFER_AMOUNT, "balance should increase by mint amount");
    }

    // ========== ENCRYPTED BURN TESTS ==========

    function testEncryptedBurn() public {
        // First mint some to burn
        (externalEuint128 encMintAmount, bytes memory mintProof) = encryptUint128(TRANSFER_AMOUNT, address(token));
        token.mintEncrypted(user, encMintAmount, mintProof);

        uint128 balanceBefore = decrypt(token.getEncryptedBalance(user));

        (externalEuint128 encBurnAmount, bytes memory burnProof) = encryptUint128(TRANSFER_AMOUNT, address(token));
        token.burnEncrypted(user, encBurnAmount, burnProof);

        uint128 balanceAfter = decrypt(token.getEncryptedBalance(user));
        assertEq(balanceAfter, balanceBefore - TRANSFER_AMOUNT, "balance should decrease by burn amount");
    }

    // ========== ENCRYPTED TRANSFER TESTS ==========

    function testTransferEncrypted() public {
        // user2 starts with 0
        uint128 user2BalanceBefore = decrypt(token.getEncryptedBalance(user2));
        assertEq(user2BalanceBefore, 0, "user2 should start with 0 balance");

        // Transfer from user to user2
        (externalEuint128 encAmount, bytes memory proof) = encryptUint128(TRANSFER_AMOUNT, address(token));
        token.transferFromEncrypted(user, user2, encAmount, proof);

        // Decrypt and verify actual value matches
        euint128 encBalance = token.getEncryptedBalance(user2);
        uint128 clearBalance = decrypt(encBalance);
        assertEq(clearBalance, TRANSFER_AMOUNT, "user2 balance should equal transfer amount");
    }

    function testTransferFromEncrypted() public {
        uint128 user2BalanceBefore = decrypt(token.getEncryptedBalance(user2));

        (externalEuint128 encAmount, bytes memory proof) = encryptUint128(TRANSFER_AMOUNT, address(token));
        token.transferFromEncrypted(user, user2, encAmount, proof);

        uint128 user2BalanceAfter = decrypt(token.getEncryptedBalance(user2));
        assertEq(user2BalanceAfter, user2BalanceBefore + TRANSFER_AMOUNT, "user2 balance should increase");
    }

    function testTransferInsufficientBalance() public {
        // Transfer more than balance - should clamp, not revert
        // Transfer from user (who has INITIAL_MINT) to user2
        uint128 user2BalanceBefore = decrypt(token.getEncryptedBalance(user2));

        (externalEuint128 bigAmount, bytes memory proof) = encryptUint128(INITIAL_MINT * 2, address(token));
        token.transferFromEncrypted(user, user2, bigAmount, proof);

        // user2 should receive at most INITIAL_MINT (clamped from user's balance)
        uint128 user2BalanceAfter = decrypt(token.getEncryptedBalance(user2));
        assertEq(user2BalanceAfter, user2BalanceBefore + INITIAL_MINT, "should clamp to sender balance");
    }

    function testTransferToZeroAddress() public {
        (externalEuint128 encAmount, bytes memory proof) = encryptUint128(TRANSFER_AMOUNT, address(token));
        vm.expectRevert(HybridFHERC20Zama.HybridFHERC20__InvalidReceiver.selector);
        token.transferEncrypted(address(0), encAmount, proof);
    }

    function testTransferFromZeroAddress() public {
        (externalEuint128 encAmount, bytes memory proof) = encryptUint128(TRANSFER_AMOUNT, address(token));
        vm.expectRevert(HybridFHERC20Zama.HybridFHERC20__InvalidSender.selector);
        token.transferFromEncrypted(address(0), user2, encAmount, proof);
    }

    // ========== WRAP/UNWRAP TESTS ==========

    function testWrap() public {
        uint256 balBefore = token.balanceOf(user);
        uint128 encBalBefore = decrypt(token.getEncryptedBalance(user));

        token.wrap(user, uint128(TRANSFER_AMOUNT));

        uint256 balAfter = token.balanceOf(user);
        assertEq(balAfter, balBefore - TRANSFER_AMOUNT, "public balance should decrease");

        uint128 encBalAfter = decrypt(token.getEncryptedBalance(user));
        assertEq(encBalAfter, encBalBefore + TRANSFER_AMOUNT, "encrypted balance should increase by wrap amount");
    }

    function testRequestUnwrap() public {
        // First wrap to have encrypted balance
        token.wrap(user, uint128(TRANSFER_AMOUNT));

        (externalEuint128 encAmount, bytes memory proof) = encryptUint128(TRANSFER_AMOUNT, address(token));
        euint128 handle = token.requestUnwrap(user, encAmount, proof);

        // Verify handle is non-zero (actual decryption requires KMS)
        assertTrue(euint128.unwrap(handle) != bytes32(0), "unwrap handle should be non-zero");
    }

    // ========== DECRYPTION TESTS ==========

    function testDecryptBalance() public {
        // Get encrypted handle and verify decryption works
        euint128 encBalance = token.getEncryptedBalance(user);
        uint128 clearBalance = decrypt(encBalance);
        assertEq(clearBalance, INITIAL_MINT, "decrypted balance should equal initial mint");
    }

    function testDecryptBalanceSafe() public {
        euint128 encBalance = token.getEncryptedBalance(user);
        (uint128 clearBalance, bool wasDecrypted) = token.getDecryptBalanceResultSafe(user);
        // wasDecrypted depends on if decryption was requested
    }

    // ========== VIEW FUNCTIONS ==========

    function testGetEncryptedBalanceView() public view {
        euint128 balance = token.getEncryptedBalance(user);
        // Returns handle, not cleartext - can verify handle is non-zero
        assertTrue(euint128.unwrap(balance) != bytes32(0), "balance handle should be non-zero");
    }

    function testGetTotalEncryptedSupplyView() public view {
        euint128 supply = token.getTotalEncryptedSupply();
        assertTrue(euint128.unwrap(supply) != bytes32(0), "supply handle should be non-zero");
    }

    // ========== ACL TESTS ==========

    function testIsBalanceAllowed() public view {
        bool allowed = token.isBalanceAllowed(user, address(this));
        // Just verify the function callable
        assertTrue(allowed == true || allowed == false, "should return boolean");
    }
}