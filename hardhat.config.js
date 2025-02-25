require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    // Add your network configurations here
    hardhat: {
      forking: {
        // If you want to fork mainnet
        url: process.env.MAINNET_RPC_URL,
      },
    },
    // Add other networks as needed
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
}; 