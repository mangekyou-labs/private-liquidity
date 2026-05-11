// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library PrivacyLib {
    struct Ciphertext {
        bytes data;
    }

    function encryptUint(uint256 plain, bytes32 key) internal pure returns (Ciphertext memory) {
        return Ciphertext(abi.encode(plain ^ uint256(key)));
    }

    function decryptUint(Ciphertext memory cipher, bytes32 key) internal pure returns (uint256) {
        uint256 masked = abi.decode(cipher.data, (uint256));
        return masked ^ uint256(key);
    }
}

