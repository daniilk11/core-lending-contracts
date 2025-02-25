const hre = require("hardhat");

async function main() {
  // 1. Deploy mock tokens first (if needed)
  const MockERC20 = await hre.ethers.getContractFactory("MockERC20");
  const mockToken = await MockERC20.deploy("Mock Token", "MTK");
  await mockToken.deployed();
  console.log("MockERC20 deployed to:", mockToken.address);

  // 2. Deploy MockStaking
  const MockStaking = await hre.ethers.getContractFactory("MockStaking");
  const mockStaking = await MockStaking.deploy(mockToken.address);
  await mockStaking.deployed();
  console.log("MockStaking deployed to:", mockStaking.address);

  // 3. Deploy Lending contract
  // You'll need the Uniswap Router address for your network
  const UNISWAP_ROUTER_ADDRESS = "0xE592427A0AEce92De3Edee1F18E0157C05861564"; // Mainnet address

  const Lending = await hre.ethers.getContractFactory("Lending");
  const lending = await Lending.deploy(UNISWAP_ROUTER_ADDRESS);
  await lending.deployed();
  console.log("Lending deployed to:", lending.address);

  // 4. Setup allowed tokens
  // You'll need a price feed address for your token
  const MOCK_PRICE_FEED_ADDRESS = "YOUR_PRICE_FEED_ADDRESS";
  
  await lending.setAllowedToken(
    mockToken.address,
    MOCK_PRICE_FEED_ADDRESS,
    "Compound Mock Token",
    "cMTK",
    mockStaking.address
  );
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 