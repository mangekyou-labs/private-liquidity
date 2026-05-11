import { HardhatUserConfig } from 'hardhat/config'
import '@nomicfoundation/hardhat-toolbox'
import '@nomicfoundation/hardhat-foundry'
import '@nomicfoundation/hardhat-ethers'

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.25',
    settings: {
      evmVersion: 'cancun',
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    localhost: {
      url: 'http://127.0.0.1:8545',
      chainId: 31337,
    },
    sepolia: {
      url: `https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`,
      chainId: 11155111,
      accounts: {
        mnemonic: process.env.MNEMONIC || '',
      },
    },
    // Zama fhEVM testnet (bh-497571)
    'zama-sepolia': {
      url: 'https://devnet.zama.ai',
      chainId: 497571,
      accounts: {
        mnemonic: process.env.MNEMONIC || '',
      },
    },
  },
}

export default config