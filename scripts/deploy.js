const { ethers } = require("hardhat");
require("dotenv").config();

async function main() {
  // Verify environment variables
  console.log("Checking environment variables...");
  if (!process.env.BASE_SEPOLIA_RPC_URL) {
    throw new Error("BASE_SEPOLIA_RPC_URL not found in environment variables");
  }
  if (!process.env.PRIVATE_KEY) {
    throw new Error("PRIVATE_KEY not found in environment variables");
  }
  if (!process.env.BASESCAN_API_KEY) {
    throw new Error("BASESCAN_API_KEY not found in environment variables");
  }
  console.log("Environment variables verified successfully!");

  console.log("Starting deployment...");

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // Deploy mock tokens
  console.log("\nDeploying MockERC20 tokens...");
  const MockERC20Factory = await ethers.getContractFactory("MockERC20");
  const mockUSDC = await MockERC20Factory.deploy("Mock USDC", "USDC");
  await mockUSDC.waitForDeployment();
  console.log("MockUSDC deployed to:", await mockUSDC.getAddress());

  const mockWETH = await MockERC20Factory.deploy("Mock WETH", "WETH");
  await mockWETH.waitForDeployment();
  console.log("MockWETH deployed to:", await mockWETH.getAddress());

  // Deploy mock price feeds
  console.log("\nDeploying MockV3Aggregator...");
  const MockV3AggregatorFactory = await ethers.getContractFactory("MockV3Aggregator");
  const usdcPriceFeed = await MockV3AggregatorFactory.deploy(8, 100000000); // $1
  await usdcPriceFeed.waitForDeployment();
  console.log("USDC Price Feed deployed to:", await usdcPriceFeed.getAddress());

  const wethPriceFeed = await MockV3AggregatorFactory.deploy(8, 200000000000); // $2000
  await wethPriceFeed.waitForDeployment();
  console.log("WETH Price Feed deployed to:", await wethPriceFeed.getAddress());

  // Deploy mock swap router
  console.log("\nDeploying MockSwapRouter...");
  const MockSwapRouterFactory = await ethers.getContractFactory("MockSwapRouter");
  const mockRouter = await MockSwapRouterFactory.deploy(
    await mockWETH.getAddress(),
    await mockUSDC.getAddress()
  );
  await mockRouter.waitForDeployment();
  console.log("MockSwapRouter deployed to:", await mockRouter.getAddress());

  // Deploy staking contracts
  console.log("\nDeploying MockStaking contracts...");
  const MockStakingFactory = await ethers.getContractFactory("MockStaking");
  const usdcStaking = await MockStakingFactory.deploy(await mockUSDC.getAddress());
  await usdcStaking.waitForDeployment();
  console.log("USDC Staking deployed to:", await usdcStaking.getAddress());

  const wethStaking = await MockStakingFactory.deploy(await mockWETH.getAddress());
  await wethStaking.waitForDeployment();
  console.log("WETH Staking deployed to:", await wethStaking.getAddress());

  // Deploy lending contract
  console.log("\nDeploying Lending contract...");
  const LendingFactory = await ethers.getContractFactory("Lending");
  const lending = await LendingFactory.deploy(await mockRouter.getAddress());
  await lending.waitForDeployment();
  console.log("Lending contract deployed to:", await lending.getAddress());

  // Deploy CTokens
  console.log("\nDeploying CToken contracts...");
  const CTokenFactory = await ethers.getContractFactory("CToken");
  const usdcCToken = await CTokenFactory.deploy(
    await mockUSDC.getAddress(),
    "USDC",
    "cUSDC",
    await usdcStaking.getAddress(),
    await lending.getAddress()
  );
  await usdcCToken.waitForDeployment();
  console.log("USDC CToken deployed to:", await usdcCToken.getAddress());

  const wethCToken = await CTokenFactory.deploy(
    await mockWETH.getAddress(),
    "WETH",
    "cWETH",
    await wethStaking.getAddress(),
    await lending.getAddress()
  );
  await wethCToken.waitForDeployment();
  console.log("WETH CToken deployed to:", await wethCToken.getAddress());

  // Setup allowed tokens in lending contract
  console.log("\nSetting up allowed tokens in lending contract...");
  await lending.setAllowedToken(
    await mockUSDC.getAddress(),
    await usdcCToken.getAddress(),
    await usdcPriceFeed.getAddress(),
    await usdcStaking.getAddress()
  );
  console.log("USDC token setup complete");

  await lending.setAllowedToken(
    await mockWETH.getAddress(),
    await wethCToken.getAddress(),
    await wethPriceFeed.getAddress(),
    await wethStaking.getAddress()
  );
  console.log("WETH token setup complete");

  // Log all deployed addresses
  console.log("\nDeployment Summary:");
  console.log("-------------------");
  console.log("MockUSDC:", await mockUSDC.getAddress());
  console.log("MockWETH:", await mockWETH.getAddress());
  console.log("USDC Price Feed:", await usdcPriceFeed.getAddress());
  console.log("WETH Price Feed:", await wethPriceFeed.getAddress());
  console.log("MockSwapRouter:", await mockRouter.getAddress());
  console.log("USDC Staking:", await usdcStaking.getAddress());
  console.log("WETH Staking:", await wethStaking.getAddress());
  console.log("Lending Contract:", await lending.getAddress());
  console.log("USDC CToken:", await usdcCToken.getAddress());
  console.log("WETH CToken:", await wethCToken.getAddress());
  console.log("\nDeployment completed successfully!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 