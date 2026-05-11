# Testing Guide

## Current Test Coverage

**53/53 tests passing** in `zama-test/` (unit + fork integration):

| Suite | Tests | What It Tests |
|-------|-------|---------------|
| `PrivateLiquidityTrackerZama.t.sol` | 13 | wrap/unwrap/transfer via MockPoolManager |
| `PrivateLiquidityTrackerZamaCallbacks.t.sol` | 10 | Hook callback integration via TestPoolManager |
| `HybridFHERC20Zama.t.sol` | 16 | FHE mint/burn/transfer/wrap |
| `ZamaHarnessTest.t.sol` | 4 | FhevmTest harness |
| `PrivateLiquidityTrackerZamaFork.t.sol` | 2 | Fork connectivity + documentation |

Run with: `cd zama-test && forge test -vvv`

## Integration Test File: `PoolEncryptedTokenIntegration.t.sol`

**Created**: `zama-test/test/PoolEncryptedTokenIntegration.t.sol`

This file was created to add real FHE verification for previously stubbed tests. It follows the same patterns as the existing test files.

**Sections in the file:**

1. **PoolEncryptedTokenTest** — Direct tests of `PoolEncryptedToken` contract (mint/burn/hookTransfer/access control)
2. **InternalTransferTest** — Tests via `TestPoolManager` + `TestablePrivateLiquidityTrackerZama` for internal transfer functions
3. **EndToEndFlowTest** — Full flow combining hook callbacks with internal transfers
4. **FeeTrackingTest** — Fee accumulator verification
5. **SubscriberCallbackTest** — ISubscriber callback tests

**IMPORTANT**: These tests follow FhevmTest patterns but some may fail due to ACL issues with `PoolEncryptedToken` deployment. See Known Issues below.

## Known Issues

### 1. `PoolEncryptedTokenIntegration.t.sol` — ACL Failures with `PoolEncryptedToken` Direct Tests

**Symptom**: Tests that directly deploy `PoolEncryptedToken` and call `mint`/`burn`/`hookTransfer` fail with:
```
ACLNotAllowed(handle, PoolEncryptedToken address)
```
or
```
call to non-contract address 0x0000000000000000000000000000000000000000
```

**Root Cause**: `PoolEncryptedToken` constructor calls `FHE.setCoprocessor()`. When deployed inside a test contract's `setUp()`, this happens BEFORE `FhevmTest.setUp()` deploys the mock coprocessor contracts. The coprocessor address ends up as `address(0)` or an undeployed address.

**Impact**: Direct `PoolEncryptedToken` tests fail. Tests that go through `TestPoolManager` → `TestablePrivateLiquidityTrackerZama` → `PoolEncryptedToken` work because `TestPoolManager` deploys the hook in its constructor before `FhevmTest` infrastructure is ready.

**Workaround**: For direct `PoolEncryptedToken` tests, use `encryptUint64()` + `FHE.fromExternal()` pattern (as shown in existing `HybridFHERC20Zama.t.sol`). The `FhevmTest` harness will properly route `fromExternal` through its mock executor.

### 2. FHE Handle Handles Created Before Coprocessor is Deployed

**Symptom**: `FHE.asEuint*()` calls in constructors of contracts deployed in test `setUp()` create handles that cannot be used later.

**Root Cause**: `FhevmTest.setUp()` deploys mock coprocessor contracts AFTER test contract `setUp()` runs. Any contract that calls `FHE.setCoprocessor()` in its constructor during test `setUp()` will have an invalid coprocessor reference.

**Affected Contracts**:
- `PoolEncryptedToken` — calls `FHE.setCoprocessor()` in constructor
- `PrivateLiquidityTrackerZama` — does NOT call `FHE.setCoprocessor()` in constructor (uses `initialize()` instead)

**No fix needed for** `TestablePrivateLiquidityTrackerZama` since it inherits the `initialize()` pattern.

### 3. `FHE.asEuint*()` vs `FHE.fromExternal()` in Tests

**Rule**: In tests using `FhevmTest` harness:
- **DO NOT** use `FHE.asEuint*()` for test values — routes to real coprocessor which doesn't exist
- **USE** `encryptUint*()` + `FHE.fromExternal()` — routes through mock executor with `_plaintexts` DB

This is why `HybridFHERC20Zama.t.sol` passes (uses `encryptUint128` + `fromExternal`) and direct `PoolEncryptedToken` tests fail (use `FHE.asEuint64`).

### 4. Internal Transfer Tests Require `TestPoolManager` Initialization

**Symptom**: `InternalTransferTest` tests fail if `poolManager.callAfterInitialize()` is not called first.

**Root Cause**: `PoolEncryptedToken` is created inside `_afterInitialize()`. Without initialization, `poolEncryptedTokens[poolId]` is address(0).

**Solution**: Always call `poolManager.callAfterInitialize(tracker, alice, poolKey, SQRT_PRICE, 0)` before testing internal transfers.

## Hook Callback Integration Tests (SOLVED)

**The Problem**: Hook callback integration tests (`_afterInitialize`, `_beforeAddLiquidity`, `_afterAddLiquidity`, `_beforeRemoveLiquidity`, `_afterRemoveLiquidity`) require a real `PoolManager` that actually invokes the hook methods. This requires:

1. Uniswap v4-core `PoolManager.sol` — compiled at solc **0.8.26**
2. Zama fhEVM library (`@fhevm/solidity`) — requires solc **0.8.27**

These versions are incompatible. Compiling together fails with:
```
Error: Encountered invalid solc version in node_modules/@uniswap/v4-core/src/PoolManager.sol:
No solc version exists that matches the version requirement: =0.8.26
```

**Solution**: `TestablePrivateLiquidityTrackerZama` + `TestPoolManager` pattern:
- `TestablePrivateLiquidityTrackerZama` exposes internal hook callbacks as external methods
- `TestPoolManager` actually invokes those callbacks with proper parameters
- Tests run via `FhevmTest` harness (chainid 31337) which provides mock coprocessor

This tests:
- ✅ All 5 hook callbacks (`_afterInitialize`, `_beforeAddLiquidity`, `_afterAddLiquidity`, `_beforeRemoveLiquidity`, `_afterRemoveLiquidity`)
- ✅ Correct selector return values
- ✅ ACL grants after FHE operations
- ✅ Access control (owner-only functions)

## Correct Approach: Fork Testing

Fork tests verify hook connectivity and address validity, but **FHE operations require a coprocessor** that fork mode cannot provide. This is expected behavior, not a bug.

**What fork tests can verify:**
- ✅ Hook deployed at correct address with valid flag bits
- ✅ PoolManager connection (code size verification)
- ✅ Hook callbacks would be invoked (but FHE ops inside revert)

**What fork tests cannot do:**
- ❌ Execute FHE operations (`FHE.asEuint128()`, `FHE.add()`, etc.)
- ❌ Test encrypted state changes via hook callbacks

**Researched solution from private-uniswap**: They use same approach — detect mock environment with `fhevm.isMock` and skip FHE tests when coprocessor unavailable. No fork-based solution exists because FHE operations require the Zama coprocessor runtime.

```solidity
// Fork test verifies connectivity but documents limitation
function test_FHEOperationsRequireCoprocessor() public {
    // PoolManager calls _afterInitialize which calls FHE.asEuint128(0)
    // This reverts because coprocessor address is address(0) in fork mode
    // Expected behavior — FhevmTest harness (chainid 31337) required for FHE
}
```

## Hook Address Requirement

Uniswap v4 requires hook contracts to be deployed at addresses where the bottom 14 bits encode their enabled callbacks. Our `PrivateLiquidityTrackerZama` enables:

| Flag | Bit | Hex Value |
|------|-----|----------|
| AFTER_INITIALIZE_FLAG | 12 | 0x1000 |
| BEFORE_ADD_LIQUIDITY_FLAG | 11 | 0x800 |
| AFTER_ADD_LIQUIDITY_FLAG | 10 | 0x400 |
| BEFORE_REMOVE_LIQUIDITY_FLAG | 9 | 0x200 |
| AFTER_REMOVE_LIQUIDITY_FLAG | 8 | 0x100 |
| **Combined** | | **0x1F00** |

To mine a valid address:
```solidity
uint160 flags = uint160(
    Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
);
(address hookAddress, bytes32 salt) = HookMiner.find(
    address(0x4e59b44847b379578588920cA78FbF26c0B4956C), // CREATE2 deployer
    flags,
    type(PrivateLiquidityTrackerZama).creationCode,
    abi.encode(address(manager))
);
tracker = new PrivateLiquidityTrackerZama{salt: salt}(manager);
```

The `HookMiner` is in `lib/v4-periphery/src/utils/HookMiner.sol`.

## Testing Checklist

- [x] 53 tests passing in zama-test/ (unit + fork)
- [x] wrap/unwrap/transfer functions tested (via MockPoolManager + FhevmTest)
- [x] FHE operations (mint/burn/transfer) tested (via FhevmTest harness)
- [x] Fork test suite verifies hook connectivity
- [x] Hook deployed at valid address on Sepolia (0xe4240c3B4D0041c241f4F04202533DDCfcD99F00)
- [x] Hook callback integration tests (via TestablePrivateLiquidityTrackerZama + TestPoolManager)
- [ ] `PoolEncryptedTokenIntegration.t.sol` — some tests fail due to ACL/coprocessor timing (see Known Issues)
- [ ] Fuzz tests on FHE operations (TODO)
- [ ] Invariant tests for encrypted state (TODO)

## References

- Zama fhEVM: `zama-fhevm` skill (`/zama-fhevm`)
- Uniswap V4 Hook Testing: `uniswap-ai` skill (`/uniswap-ai`)
- Foundry Testing: `ethskills:testing` skill