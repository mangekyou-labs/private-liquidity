# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Privacy-preserving perpetual futures protocol using Fully Homomorphic Encryption (FHE). Built as Uniswap V4 hooks. Uses **Zama fhEVM** as primary (and only) FHE library.

## Build & Test Commands

```bash
# Primary workspace (Zama FHE contracts)
cd zama-test
forge build --via-ir
forge test -vvv                    # Run all passing tests
forge test --match-test testName -vvv   # Run single test
forge test --match-path test/PrivateLiquidityTrackerZamaCallbacks.t.sol -vvv  # Hook callback tests

# Exclude PoolEncryptedTokenIntegration.t.sol (ACL timing issues with standalone deployment):
forge test --no-match-path test/PoolEncryptedTokenIntegration.t.sol -vvv
```

**Test Status**: 53 tests passing. `PoolEncryptedTokenIntegration.t.sol` has 23 failing tests due to FhevmTest harness timing - the mock coprocessor contracts aren't available at `new PoolEncryptedToken()` deployment time in test setUp. This affects only the direct `PoolEncryptedToken` tests, not the hook flow.

## Tech Stack

- **FHE Library**: Zama fhEVM (`@fhevm/solidity`, `^0.8.27`)
- **Contracts**: Solidity 0.8.27 (zama-test), 0.8.26 (root)
- **Build**: Foundry (Forge), via-ir pipeline
- **Privacy**: Fully Homomorphic Encryption on-chain
- **DEX**: Uniswap V4 (hooks, core, periphery)

## Architecture

### Two Sub-Projects

| Directory | solc | Purpose |
|-----------|------|---------|
| `zama-test/` | 0.8.27 | Zama FHE token + hook implementations (primary dev workspace) |
| `root` | 0.8.26 | Non-FHE base contracts only |

Zama FHE code lives in `zama-test/` only. Root `foundry.toml` cannot build Zama code due to solc version mismatch.

### Source Files (zama-test/src/)

```
PrivateLiquidityTrackerZama.sol        # Uniswap V4 hook - tracks encrypted LP shares + fees
PrivateLiquidityTrackerZamaSubscriber.sol  # ISubscriber - NFT position subscription
PoolEncryptedToken.sol                # ERC7984-style internal transfer token per pool
HybridFHERC20Zama.sol                 # Hybrid ERC20 with FHE balances
libraries/IntentTypes.sol            # LP intent structs (minimal, deferred)
```

### Hook Callbacks Enabled

`PrivateLiquidityTrackerZama` enables: `afterInitialize`, `beforeAddLiquidity`, `afterAddLiquidity`, `beforeRemoveLiquidity`, `afterRemoveLiquidity`.

**Hook address requirement**: Uniswap V4 requires bottom 14 bits encode enabled callbacks. Address must be mined with `HookMiner.find()` using flags `0x1F00`.

## Zama fhEVM Testing

Tests use `FhevmTest` harness on chainid 31337 (mock coprocessor).

```solidity
import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {FHE, euint128} from "@fhevm/solidity/lib/FHE.sol";
import {externalEuint128} from "encrypted-types/EncryptedTypes.sol";

contract MyTokenTest is FhevmTest {
    function testEncryptedTransfer() public {
        (externalEuint128 encAmount, bytes memory proof) = encryptUint128(100, address(this));
        token.transferEncrypted(user2, encAmount, proof);
        euint128 encBalance = token.getEncryptedBalance(user2);
        uint128 clearBalance = decrypt(encBalance);
        assertEq(clearBalance, 100);
    }
}
```

**Key rules:**
- Use `encryptUint128(value, target)` for test encryption
- Use `FHE.fromExternal(encrypted, proof)` to convert external→internal
- Use `decrypt(encryptedValue)` to read mock decrypted values
- **DO NOT use `FHE.asEuint128()` in tests** - routes to real executor
- Tests run on chainid 31337 (FhevmTest sets it automatically)

### ACL Ordering (Critical)

Grant ACL on result handles AFTER FHE operations:

```solidity
function _mintEnc(address to, euint128 amount) internal {
    euint128 newBalance = FHE.add(encryptedBalances[to], amount);
    encryptedBalances[to] = newBalance;
    FHE.allowThis(newBalance);   // AFTER FHE ops
    FHE.allow(newBalance, to);   // AFTER FHE ops
}
```

### Hook Callback Testing Pattern

Hook callbacks require real PoolManager but Uniswap v4-core is solc 0.8.26 while Zama requires 0.8.27 - incompatible.

**Solution**: `TestablePrivateLiquidityTrackerZama` exposes internal callbacks as external; `TestPoolManager` invokes them with proper parameters.

See `zama-test/TESTING.md` for full details.

### PoolEncryptedToken Initialization

`PoolEncryptedToken` requires `initialize()` call after deployment (FHE not available in constructor):

```solidity
PoolEncryptedToken encToken = new PoolEncryptedToken({...});
encToken.initialize();  // Sets up FHE coprocessor + initial state
```

## Key Config

- `zama-test/foundry.toml`: solc 0.8.27, `isolate = true`, `via_ir = true`
- `foundry.toml` (root): solc 0.8.26
- FHE operations require `isolate = true`

## Directory Structure

```
zama-test/
  src/
    PrivateLiquidityTrackerZama.sol   # Main hook contract
    PrivateLiquidityTrackerZamaSubscriber.sol  # ISubscriber for NFT positions
    PoolEncryptedToken.sol            # ERC7984 internal transfer token
    HybridFHERC20Zama.sol            # FHE ERC20 token
  test/                 # 53 tests across 5 suites
  lib/forge-fhevm/      # Zama test harness (FhevmTest)
  TESTING.md           # Full testing guide
script/
  DeployHook.s.sol     # Hook deployment script
lib/                    # Git submodules: v4-core, v4-periphery, forge-fhevm
dependencies/           # forge-fhevm
```

## Reference Implementation

**tomi204/private-uniswap** (GitHub) — PrivacyPoolHook with encrypted intents, batch settlement, and ERC7984 tokens.

## NFT Position Subscription Flow

1. Call `PrivateLiquidityTrackerZama.setPositionManager(positionManagerAddr)` once
2. Call `PrivateLiquidityTrackerZama.subscribeToPosition(tokenId, subscriberContract)` - auto-calls `PositionManager.subscribe(tokenId, subscriber, data)`
3. PositionManager invokes `ISubscriber.notifySubscribe/notifyModifyLiquidity/notifyBurn` on the subscriber

## Known Issues

1. **`ISubscriber.notifySubscribe` cannot read NFT owner** — `IPositionManager` doesn't expose `ownerOf()`. Uses `msg.sender` as proxy.

2. **IntentTypes.sol is minimal** — structs only, no batch settlement, no relayer integration. Deferred.

3. **Fork tests limited** — `PrivateLiquidityTrackerZamaFork.t.sol` tests against Sepolia but FHE ops require coprocessor. These are connectivity tests only.

4. **FHE Library Version Conflict** — Root `foundry.toml` solc 0.8.26 vs Zama `forge-fhevm` requires `^0.8.27`. Don't import Zama FHE files in root scope.

5. **`PoolEncryptedTokenIntegration.t.sol` partial failures** — 23 tests fail due to ACL timing. Direct `PoolEncryptedToken` deployment in test `setUp()` runs before FhevmTest mock contracts deploy. Tests through `TestPoolManager` → hook → `PoolEncryptedToken` work correctly.
