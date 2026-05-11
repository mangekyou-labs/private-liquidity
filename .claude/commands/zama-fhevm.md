# Zama fhEVM Developer Guide

Zama's fhEVM enables FHE (Fully Homomorphic Encryption) on EVM chains. Different from Fhenix CoFHE.

## Quick Reference

| Topic | Pattern |
|-------|---------|
| Import | `import {FHE} from "@fhevm/solidity/lib/FHE.sol"` |
| Coprocessor | `FHE.setCoprocessor(CoprocessorSetup.defaultConfig())` |
| Encrypt plaintext | `FHE.asEuint128(value)` |
| External encrypted input | `FHE.fromExternal(externalEuint128, inputProof)` |
| Grant contract access | `FHE.allowThis(handle)` |
| Grant user access | `FHE.allow(handle, userAddress)` |
| Request decryption | `FHE.makePubliclyDecryptable(handle)` |
| ACL check | `require(FHE.isSenderAllowed(amount))` |

## Contract Setup

```solidity
pragma solidity ^0.8.24;

import {FHE, CoprocessorConfig} from "@fhevm/solidity/lib/FHE.sol";
import {CoprocessorSetup} from "@fhevm/solidity/config/ZamaConfig.sol";

contract MyContract {
    function initialize() internal {
        FHE.setCoprocessor(CoprocessorSetup.defaultConfig());
    }
}
```

## ACL Pattern (Critical)

Zama uses handles + ACL grants. Every encrypted value is a handle.

**IMPORTANT**: Grant ACL on result handles AFTER FHE operations, not before. The FHE executor validates ACL on input handles BEFORE computation, but stores result in a new handle that needs ACL after the operation.

```solidity
// Store encrypted value
mapping(address => euint128) public encryptedBalances;

// Correct ACL ordering: FHE ops first, then grant ACL on results
function _mintEnc(address to, euint128 amount) internal {
    // Do FHE operations first
    euint128 newBalance = FHE.add(encryptedBalances[to], amount);
    euint128 newSupply = FHE.add(totalEncSupply, amount);

    // Store results
    encryptedBalances[to] = newBalance;
    totalEncSupply = newSupply;

    // Grant ACL AFTER FHE operations on result handles
    FHE.allowThis(newBalance);
    FHE.allow(newBalance, to);
    FHE.allowThis(newSupply);
    FHE.allow(newSupply, to);

    emit EncryptedMint(to, bytes32(euint128.unwrap(amount)));
}
```

### Why ACL Ordering Matters

When the FHE executor processes `FHE.add(lhs, rhs)`:
1. Validates ACL on `lhs` and `rhs` (input handles) - MUST be allowed
2. Computes result, creates NEW handle for result
3. ACL on result handle is NOT checked during computation

If you grant ACL on result BEFORE FHE ops:
- The result handle might not exist yet (depends on implementation)
- If it does exist from a previous operation, you're granting on wrong handle

**Golden rule**: Do FHE operations, store in temp variable, then grant ACL on that temp variable.

## External Encrypted Input

dApps send encrypted values with proof:

```solidity
function transfer(
    address to,
    externalEuint128 encryptedAmount,
    bytes calldata inputProof
) external returns (bool) {
    euint128 amount = FHE.fromExternal(encryptedAmount, inputProof);
    // use amount...
}
```

## Transfer Pattern

```solidity
function transfer(address to, euint128 amount) public returns (bool) {
    // Verify sender owns the handle
    require(FHE.isSenderAllowed(amount));

    // Clamp to balance (prevents underflow)
    euint128 amountToSend = FHE.select(
        FHE.gt(amount, encryptedBalances[msg.sender]),
        encryptedBalances[msg.sender],
        amount
    );

    encryptedBalances[to] = FHE.add(encryptedBalances[to], amountToSend);
    encryptedBalances[from] = FHE.sub(encryptedBalances[from], amountToSend);

    return true;
}
```

## Decryption Flow

Two-step: request + finalize (off-chain KMS):

```solidity
// Step 1: Request public decryption
function decryptBalance(address user) external {
    FHE.allowForDecryption(encryptedBalances[user]);
    FHE.makePubliclyDecryptable(encryptedBalances[user]);
    // Off-chain coprocessor processes, posts result via KMS
}

// Step 2: Finalize with KMS proof
function finalizeUnwrap(
    address user,
    euint128 burnAmount,
    uint128 decryptedAmount,
    bytes calldata decryptionProof
) external {
    // Verify KMS signature
    FHE.checkSignatures(
        _toBytes32List(burnAmount),
        abi.encodePacked(decryptedAmount),
        decryptionProof
    );
    // Burn encrypted, mint public...
}
```

## Required foundry.toml

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.24"  # or 0.8.27
evm_version = "cancun"  # REQUIRED for FHE
optimizer = true
optimizer_runs = 800
cbor_metadata = false
bytecode_hash = "none"
isolate = true  # REQUIRED for FHE permission checks
via_ir = true  # REQUIRED for FHE operations

[dependencies]
forge-fhevm = { version = "eba2324", git = "https://github.com/zama-ai/forge-fhevm.git", rev = "eba2324" }
```

## Required remappings.txt

```
@fhevm/solidity/=lib/fhevm/library-solidity/
encrypted-types/=lib/fhevm/library-solidity/node_modules/encrypted-types/
forge-fhevm/=lib/forge-fhevm/src/
```

## Testing with FhevmTest - Mock Executor Pattern

**IMPORTANT**: When using `FhevmTest` (forge-fhevm), the mock executor is deployed at deterministic addresses on chainid 31337. Use the helper methods, NOT `FHE.asEuint128()` directly.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {FHE, euint128} from "@fhevm/solidity/lib/FHE.sol";
import {externalEuint128} from "encrypted-types/EncryptedTypes.sol";

contract MyContractTest is FhevmTest {

    function testEncryptedTransfer() public {
        // 1. Encrypt using FhevmTest helper - stores plaintext in _plaintexts mock DB
        (externalEuint128 encAmount, bytes memory proof) = encryptUint128(100, address(token));

        // 2. Contract expects externalEuint128 - pass directly
        token.transferEncrypted(user2, encAmount, proof);

        // 3. Decrypt to verify - reads from _plaintexts mock DB
        euint128 encBalance = token.getEncryptedBalance(user2);
        uint128 clearBalance = decrypt(encBalance);
        assertEq(clearBalance, 100);
    }
}
```

### Key Points

- `encryptUint128(value, target)` stores plaintext in `_plaintexts` mock DB
- `FHE.asEuint128(value)` routes to real executor → **DO NOT use in tests**
- `FHE.fromExternal(externalHandle, proof)` reuses handle from encryption (verifies proof)
- `decrypt(handle)` reads from mock `_plaintexts` DB
- View functions return handles, not cleartext - cannot decrypt view results in tests

### Chainid Requirement

`FhevmTest.setUp()` calls `vm.chainId(31337)`. Mock contracts only deploy correctly on chainid 31337.

### Known Issue: Constructor setCoprocessor Timing

If a contract calls `FHE.setCoprocessor()` in its constructor, the call happens BEFORE `FhevmTest.setUp()` deploys mock contracts. This causes `setCoprocessor` to store address(0) as the coprocessor address.

**Workaround**: Use an initializer pattern instead:
```solidity
contract MyContract {
    bool private _initialized;
    function initialize() public {
        require(!_initialized, "already initialized");
        _initialized = true;
        FHE.setCoprocessor(ZamaConfig.getEthereumCoprocessorConfig());
    }
}
```

### Testing Without FHE.fromExternal

For tests that don't deploy a contract calling `setCoprocessor()` (e.g., `ZamaHarnessTest`), you can decrypt handles directly without `FHE.fromExternal()`:

```solidity
function testEncryptAndDecrypt() public {
    uint128 value = 100;

    // Encrypt - stores plaintext in _plaintexts
    (externalEuint128 encrypted, bytes memory proof) = encryptUint128(value, address(this));

    // Skip FHE.fromExternal - decrypt directly from handle
    // (works because _plaintexts was populated by encryptUint128)
    uint256 decrypted = decrypt(externalEuint128.unwrap(encrypted));
    assertEq(decrypted, value);
}
```

## Common Pitfalls

| Pitfall | Solution |
|---------|----------|
| `allowGlobal` doesn't exist | Don't use it. Use `allowThis` + `allow` |
| `getDecryptResult` doesn't exist | Use `checkSignatures` for verification, off-chain retrieval |
| Hardcoded ACL address | Use `CoprocessorSetup.defaultConfig()` |
| Missing `allowForDecryption` before `makePubliclyDecryptable` | Always call `FHE.allowForDecryption(handle)` first |
| No EVM version set | Must use `evm_version = "cancun"` |
| Missing `isolate = true` | Required in foundry.toml for FHE permission checks |

## Reference Contracts

- Official example: `lib/fhevm/library-solidity/examples/EncryptedERC20.sol`
- Zama foundry template: https://github.com/zama-ai/fhevm-foundry-template
- Zama docs: https://docs.zama.ai/fhevm

## FHE API Summary

### Encryption
- `FHE.asEuint128(uint128 value)` - plaintext to encrypted
- `FHE.fromExternal(externalEuint128, bytes proof)` - external input to internal

### Arithmetic
- `FHE.add(euint128 a, euint128 b)` - encrypted addition
- `FHE.sub(euint128 a, euint128 b)` - encrypted subtraction
- `FHE.select(ebool condition, euint128 a, euint128 b)` - ternary

### Comparison
- `FHE.gt(a, b)`, `FHE.lt(a, b)`, `FHE.eq(a, b)` - encrypted comparison
- Returns `ebool`

### Access Control
- `FHE.allowThis(handle)` - contract can access
- `FHE.allow(handle, address)` - specific user can access
- `FHE.allowForDecryption(handle)` - required before `makePubliclyDecryptable`
- `FHE.isSenderAllowed(handle)` - check if msg.sender can use handle
- `FHE.isAllowed(handle, address)` - check if address can use handle

### Decryption
- `FHE.makePubliclyDecryptable(handle)` - request public decryption
- `FHE.checkSignatures(handles, plaintext, proof)` - verify KMS proof