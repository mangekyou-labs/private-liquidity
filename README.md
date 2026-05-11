# Private Liquidity Tracker

Privacy-preserving liquidity provisioning on Uniswap V4 using **Zama fhEVM** (Fully Homomorphic Encryption). Hook tracks encrypted LP shares per pool. Internal transfers via ERC7984-style PoolEncryptedToken. No on-chain amounts revealed.

## Build & Test

```bash
cd zama-test
forge build --via-ir
forge test -vvv
forge test --match-test testName -vvv
forge test --match-path test/PrivateLiquidityTrackerZamaCallbacks.t.sol -vvv

# Exclude blocklisted tests (ACL timing in FhevmTest harness):
forge test --no-match-path test/PoolEncryptedTokenIntegration.t.sol -vvv
```

**Test status**: 53 tests passing. `PoolEncryptedTokenIntegration.t.sol` has 23 failing tests — root cause is FhevmTest harness deploys mock coprocessor contracts after test contract construction, so direct `PoolEncryptedToken` deployment in test `setUp()` calls `initialize()` before mocks exist. Workaround: use `TestPoolManager` pattern.

## Tech Stack

- **FHE Library**: Zama fhEVM (`@fhevm/solidity`, `^0.8.27`)
- **Contracts**: Solidity 0.8.27 (zama-test/), 0.8.26 (root/, non-FHE only)
- **Build**: Foundry (Forge), via-ir pipeline
- **DEX**: Uniswap V4 hooks + PositionManager (ERC721 NFT positions)

## Architecture

### Two Sub-Projects

| Directory | solc | Purpose |
|-----------|------|---------|
| `zama-test/` | 0.8.27 | Zama FHE contracts (primary dev workspace) |
| `root/` | 0.8.26 | Non-FHE base contracts only |

Zama FHE code lives in `zama-test/` only. Root cannot build Zama code due to solc version mismatch.

### Source Files (zama-test/src/)

```
PrivateLiquidityTrackerZama.sol        # Uniswap V4 hook - encrypted LP shares + fee tracking
PrivateLiquidityTrackerZamaSubscriber.sol  # ISubscriber - NFT position notifications
PoolEncryptedToken.sol                # ERC7984 internal transfer token per pool
HybridFHERC20Zama.sol                 # FHE ERC20 - wrap/unwrap public ↔ encrypted balances
```

### Hook Callbacks Enabled

`afterInitialize`, `beforeAddLiquidity`, `afterAddLiquidity`, `beforeRemoveLiquidity`, `afterRemoveLiquidity`.

**Hook address requirement**: Bottom 14 bits encode callbacks. Must mine address with `HookMiner.find()` using flags `0x1F00`.

### Key Contracts

**PrivateLiquidityTrackerZama** — Uniswap V4 hook. Maintains encrypted LP shares per user per pool. Tracks fee accumulation. Implements internal transfer execution via PoolEncryptedToken. Enables position subscription via ISubscriber.

**PoolEncryptedToken** — ERC7984-style confidential token per pool. Mint/burn/hookTransfer only callable by the hook. Encrypted balances via Zama FHE. Used for internal transfers between matched LP positions — no AMM touch, gas-efficient settlement.

**HybridFHERC20Zama** — ERC20 with dual balance model. Public balance for AMM compatibility. Encrypted balance for private LP activity. Users wrap public tokens into encrypted form, unwrap when exiting.

## Zama fhEVM Testing

Tests use `FhevmTest` harness on chainid 31337 (mock coprocessor, no real FHE).

```solidity
import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {FHE, euint128} from "@fhevm/solidity/lib/FHE.sol";
import {externalEuint128} from "encrypted-types/EncryptedTypes.sol";

contract MyTest is FhevmTest {
    function testEncryptedTransfer() public {
        (externalEuint128 encAmount, bytes memory proof) = encryptUint128(100, address(token));
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
- **DO NOT use `FHE.asEuint128()` in tests** — routes to real executor
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

## Known Issues

### ACL Timing in PoolEncryptedTokenIntegration.t.sol

23 tests fail due to FhevmTest harness timing. Direct `PoolEncryptedToken` deployment in test `setUp()` calls `initialize()` before mock coprocessor contracts exist. Fix: use `TestPoolManager` pattern.

### FHE Library Version Conflict

Root `foundry.toml`: `solc_version = "0.8.26"` vs Zama `forge-fhevm` requires `^0.8.27`. Don't import Zama FHE files in root scope.

---

*Built with [Zama fhEVM](https://zama.ai) and [Uniswap V4](https://uniswap.org)*