const { expect, use } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("Lending Contract", function () {
    async function deployLendingFixture() {
        // Get signers
        const [owner, user1, user2] = await ethers.getSigners();

        // Deploy mock tokens
        const MockERC20Factory = await ethers.getContractFactory("MockERC20");
        const mockUSDC = await MockERC20Factory.deploy("Mock USDC", "USDC");
        await mockUSDC.waitForDeployment();
        const mockWETH = await MockERC20Factory.deploy("Mock WETH", "WETH");
        await mockWETH.waitForDeployment();

        // Deploy mock price feeds
        const MockV3AggregatorFactory = await ethers.getContractFactory("MockV3Aggregator");
        const usdcPriceFeed = await MockV3AggregatorFactory.deploy(8, 100000000); // $1
        await usdcPriceFeed.waitForDeployment();
        const wethPriceFeed = await MockV3AggregatorFactory.deploy(8, 200000000000); // $2000
        await wethPriceFeed.waitForDeployment();

        // Deploy mock swap router with fixed rates
        const MockSwapRouterFactory = await ethers.getContractFactory("MockSwapRouter");
        const mockRouter = await MockSwapRouterFactory.deploy(
            await mockWETH.getAddress(),
            await mockUSDC.getAddress()
        );
        await mockRouter.waitForDeployment();

        // Deploy staking contracts
        const MockStakingFactory = await ethers.getContractFactory("MockStaking");
        const usdcStaking = await MockStakingFactory.deploy(mockUSDC.getAddress());
        await usdcStaking.waitForDeployment();
        const wethStaking = await MockStakingFactory.deploy(mockWETH.getAddress());
        await wethStaking.waitForDeployment();

        // Deploy lending contract first
        const LendingFactory = await ethers.getContractFactory("Lending");
        const lending = await LendingFactory.deploy(await mockRouter.getAddress());
        await lending.waitForDeployment();

        // Deploy CTokens with lending contract as owner
        const CTokenFactory = await ethers.getContractFactory("CToken");
        const usdcCToken = await CTokenFactory.deploy(
            mockUSDC.getAddress(),
            "USDC",
            "cUSDC",
            usdcStaking.getAddress(),
            lending.getAddress()
        );
        await usdcCToken.waitForDeployment();

        // Modify CToken constructor to accept owner address
        const wethCToken = await CTokenFactory.deploy(
            mockWETH.getAddress(),
            "WETH",
            "cWETH",
            wethStaking.getAddress(),
            lending.getAddress()
        );
        await wethCToken.waitForDeployment();

        // Setup allowed tokens with CTokens
        await lending.setAllowedToken(
            await mockUSDC.getAddress(),
            await usdcCToken.getAddress(),
            await usdcPriceFeed.getAddress(),
            await usdcStaking.getAddress()
        );
        await lending.setAllowedToken(
            await mockWETH.getAddress(),
            await wethCToken.getAddress(),
            await wethPriceFeed.getAddress(),
            await wethStaking.getAddress()
        );

        // Get cToken addresses
        const usdcCTokenAddress = await lending.s_tokenToCToken(await mockUSDC.getAddress());
        const wethCTokenAddress = await lending.s_tokenToCToken(await mockWETH.getAddress());

        // Mint tokens to users
        const usdcAmount = ethers.parseUnits("10000", 18);
        const wethAmount = ethers.parseUnits("10", 18);

        await mockUSDC.mint(user1.address, usdcAmount);
        await mockUSDC.mint(user2.address, usdcAmount);
        await mockUSDC.mint(usdcStaking.getAddress(), usdcAmount);
        await mockWETH.mint(user1.address, wethAmount);
        await mockWETH.mint(user2.address, wethAmount);
        await mockWETH.mint(wethStaking.getAddress(), wethAmount);

        // Add liquidity
        await mockUSDC.mint(user2.address, usdcAmount);
        await mockWETH.mint(user2.address, wethAmount);
        await mockUSDC.connect(user2).approve(mockRouter.getAddress(), usdcAmount);
        await mockRouter.connect(user2).addLiquidity(mockUSDC.getAddress(), usdcAmount);
        await mockWETH.connect(user2).approve(mockRouter.getAddress(), wethAmount);
        await mockRouter.connect(user2).addLiquidity(mockWETH.getAddress(), wethAmount);

        return {
            mockRouter,
            lending,
            mockUSDC,
            mockWETH,
            usdcPriceFeed,
            wethPriceFeed,
            owner,
            user1,
            user2,
            usdcCTokenAddress,
            wethCTokenAddress,
            usdcStaking,
            wethStaking,
            usdcCToken,
            wethCToken
        };
    }

    async function deposit(user, lending, mockToken, amount) {
        const collateralAmount = ethers.parseUnits(amount, 18);
        await mockToken.connect(user).approve(lending.getAddress(), collateralAmount);
        await lending.connect(user).deposit(mockToken.getAddress(), collateralAmount);
        console.log(" user has deposited :", amount);

        const accountCollateralValue = await lending.connect(user).healthFactor(user.getAddress());
        console.log("Now user can borrow (AccountCollateralValue) :", accountCollateralValue.toString());
    }

    async function borrow(user, lending, mockToken, amount) {
        const borrowAmount = ethers.parseUnits(amount, 18);
        await lending.connect(user).borrow(mockToken.getAddress(), borrowAmount);
    }

    async function depositInitialLiquidity(user1, user2, lending, mockUSDC, mockWETH) {
        console.log("User 1 deposit WETH $2000:");
        await deposit(user1, lending, mockWETH, "1"); // 1 WETH = $2000
        console.log("User 2 deposit USDC $2000:");
        await deposit(user2, lending, mockUSDC, "2000"); // $2000
    }

    async function depositInitialLiquidityBySecondUser(user2, lending, mockUSDC, mockWETH) {
        console.log("User 2 deposit WETH and USDC $2000 :");
        await deposit(user2, lending, mockWETH, "2"); // 1 WETH = $2000
        await deposit(user2, lending, mockUSDC, "4000"); // $2000
    }

    async function simulateBlocksTime(days) {
        // Calculate the number of blocks to mine based on the number of days
        const secondsPerBlock = 2; // Average time per block in seconds 
        const secondsInADay = 86400; // Number of seconds in a day
        const totalBlocks = Math.floor((days * secondsInADay) / secondsPerBlock); // Total blocks to mine

        console.log(`Simulating ${days} days (${totalBlocks} blocks)`);
        await ethers.provider.send("hardhat_mine", [totalBlocks.toString()]); // Mine the calculated number of blocks
    }

    describe("Deployment", function () {
        it("Should set the right owner", async function () {
            const { lending, owner } = await loadFixture(deployLendingFixture);
            expect(await lending.owner()).to.equal(await owner.getAddress());
        });

        it("Should setup allowed tokens correctly", async function () {
            const { lending, mockUSDC, mockWETH, usdcPriceFeed, wethPriceFeed } =
                await loadFixture(deployLendingFixture);

            expect(await lending.s_tokenToPriceFeed(await mockUSDC.getAddress())).to.equal(
                await usdcPriceFeed.getAddress()
            );
            expect(await lending.s_tokenToPriceFeed(await mockWETH.getAddress())).to.equal(
                await wethPriceFeed.getAddress()
            );
        });
    });

    describe("Deposits", function () {
        it("Should allow deposits and mint cTokens", async function () {
            const { lending, mockUSDC, user1, usdcCTokenAddress } = await loadFixture(
                deployLendingFixture
            );

            const depositAmount = ethers.parseUnits("100", 18);
            console.log("Deposit Amount:", depositAmount.toString());

            await mockUSDC.connect(user1).approve(await lending.getAddress(), depositAmount);
            console.log("User1 approved USDC for lending contract");

            await expect(lending.connect(user1).deposit(await mockUSDC.getAddress(), depositAmount))
                .to.emit(lending, "Deposit")
                .withArgs(user1.address, await mockUSDC.getAddress(), depositAmount);

            console.log("Deposit event emitted for user:", user1.address);

            const cToken = await ethers.getContractAt("CToken", usdcCTokenAddress);
            const userBalance = await cToken.balanceOf(user1.address);
            console.log("User1 cToken balance after deposit:", userBalance.toString());
            expect(userBalance).to.equal(depositAmount);
        });

        it("Should fail when depositing non-allowed token", async function () {
            const { lending, user1 } = await loadFixture(deployLendingFixture);

            const MockERC20Factory = await ethers.getContractFactory("MockERC20");
            const randomToken = await MockERC20Factory.deploy("Random", "RND");
            await randomToken.waitForDeployment();

            await expect(
                lending.connect(user1).deposit(await randomToken.getAddress(), 100)
            ).to.be.revertedWithCustomError(lending, "TokenNotAllowed");
        });
    });

    describe("Borrowing", function () {
        it("Should allow borrowing USDC with sufficient collateral", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(
                deployLendingFixture
            );
            await depositInitialLiquidity(user1, user2, lending, mockUSDC, mockWETH);

            // Try to borrow USDC
            const borrowAmount = ethers.parseUnits("1000", 18); // $1000 USDC
            console.log("Borrow Amount USDC:", borrowAmount.toString()); // Log borrow amount
            console.log("Borrow Amount in usdc:", await lending.getUSDValue(mockUSDC.getAddress(), borrowAmount));

            await expect(lending.connect(user1).borrow(mockUSDC.getAddress(), borrowAmount))
                .to.emit(lending, "Borrow")
                .withArgs(user1.address, mockUSDC.getAddress(), borrowAmount);

            console.log("boRROWED ", await lending.connect(user1).getAccountBorrowedValue(user1.getAddress()));
            console.log("COLLATERAL ", await lending.connect(user1).getAccountCollateralValue(user1.getAddress()));
            console.log("FACTOR IS ", await lending.connect(user1).healthFactor(user1.getAddress()));

            console.log("Borrow event emitted for user:", user1.address); // Log borrow event
        });

        it("Should allow borrowing WEth with sufficient collateral", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(
                deployLendingFixture
            );
            await depositInitialLiquidity(user1, user2, lending, mockUSDC, mockWETH);

            const borrowAmount = ethers.parseUnits("0.75", 18); // $1500 
            console.log("Borrow Amount:", borrowAmount.toString());
            console.log("Borrow Amount in usdc:", await lending.getUSDValue(mockWETH.getAddress(), borrowAmount));
            console.log("COLLATERAL ", await lending.connect(user1).getAccountCollateralValue(user1.getAddress()));
            console.log("COLLATERAL ", await lending.connect(user2).getAccountCollateralValue(user1.getAddress()));

            const cTokenAddress = await lending.s_tokenToCToken(mockWETH.getAddress());
            const cToken = await ethers.getContractAt("CToken", cTokenAddress);
            let finalUnderlyingBalance = await cToken.balanceOfUnderlying(user1.address);
            console.log("TOKEN BALANCE ", finalUnderlyingBalance);


            await expect(lending.connect(user1).borrow(mockWETH.getAddress(), borrowAmount))
                .to.emit(lending, "Borrow")
                .withArgs(user1.address, mockWETH.getAddress(), borrowAmount);

            finalUnderlyingBalance = await cToken.balanceOfUnderlying(user1.address);

            console.log("TOKEN BALANCE ", finalUnderlyingBalance);
            console.log("boRROWED ", await lending.connect(user1).getAccountBorrowedValue(user1.getAddress()));
            console.log("COLLATERAL ", await lending.connect(user1).getAccountCollateralValue(user1.getAddress()));
            console.log("FACTOR IS ", await lending.connect(user1).healthFactor(user1.getAddress()));

            console.log("Borrow event emitted for user:", user1.address); // Log borrow event
        });

        it("Should fail borrowing with insufficient collateral", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(
                deployLendingFixture
            );

            // Deposit small amount of WETH as collateral
            const collateralAmount = ethers.parseUnits("0.1", 18); // 0.1 WETH = $200
            console.log("Collateral Amount for Insufficient Borrowing:", collateralAmount.toString());

            await mockWETH.connect(user1).approve(lending.getAddress(), collateralAmount);
            console.log("User1 approved small WETH amount for lending contract");

            await lending.connect(user1).deposit(mockWETH.getAddress(), collateralAmount);
            console.log("User1 deposited small WETH as collateral");

            // Try to borrow too much USDC
            const borrowAmount = ethers.parseUnits("10000", 18); // $10000 USDC
            console.log("Attempting to borrow Amount:", borrowAmount.toString());

            const cTokenAddress = await lending.s_tokenToCToken(mockUSDC.getAddress());
            const cToken = await ethers.getContractAt("CToken", cTokenAddress);

            await expect(
                lending.connect(user1).borrow(mockUSDC.getAddress(), borrowAmount)
            ).to.be.revertedWithCustomError(cToken, "InsufficientLiquidity");

            console.log("Borrow attempt failed due to insufficient collateral");
        });
    });

    describe("Repayment", function () {
        it("Should allow repaying borrowed amounts", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(
                deployLendingFixture
            );

            // Setup: Deposit collateral and borrow
            await depositInitialLiquidity(user1, user2, lending, mockUSDC, mockWETH);

            const borrowAmount = ethers.parseUnits("1000", 18);
            await lending.connect(user1).borrow(mockUSDC.getAddress(), borrowAmount);
            console.log("User1 Borrowed 1000 USDC")

            // Repay
            await mockUSDC.connect(user1).approve(lending.getAddress(), borrowAmount);
            console.log("User1 want to repay 1000 USDC")
            await expect(lending.connect(user1).repay(mockUSDC.getAddress(), borrowAmount))
                .to.emit(lending, "Repay")
                .withArgs(user1.address, mockUSDC.getAddress(), borrowAmount);
        });
    });

    describe("Liquidation", function () {
        it("Should allow liquidation of unhealthy positions", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2, wethPriceFeed } = await loadFixture(
                deployLendingFixture
            );

            await depositInitialLiquidity(user1, user2, lending, mockUSDC, mockWETH);

            // Setup: User1 deposits collateral and borrows
            const collateralAmount = ethers.parseUnits("1", 18); // 1 WETH = $2000
            const borrowAmount = ethers.parseUnits("1000", 18); // $1000 USDC

            const prevHealthF1 = await lending.connect(user1).healthFactor(user1.getAddress());
            console.log("prevHealthF1 : ", prevHealthF1)

            await lending.connect(user1).borrow(mockUSDC.getAddress(), borrowAmount);

            const prevHealthF2 = await lending.connect(user1).healthFactor(user1.getAddress());
            console.log("prevHealthF2 : ", prevHealthF2)

            const priceUntilFall = await lending.connect(user1).getUSDValue(mockWETH.getAddress(), collateralAmount);
            console.log("priceUntilFall : ", priceUntilFall)

            await wethPriceFeed.updateAnswer(100000000000); // $1000

            const priceAfterFall = await lending.connect(user1).getUSDValue(mockWETH.getAddress(), collateralAmount);
            console.log("priceAfterFall : ", priceAfterFall)

            const nowHealthF = await lending.connect(user1).healthFactor(user1.getAddress());
            console.log("nowHealthF : ", nowHealthF)

            const br = await lending.connect(user1).getAccountBorrowedValue(user1.getAddress());
            console.log("borrow --  : ", ethers.formatUnits(br, 18))
            const col = await lending.connect(user1).getAccountBorrowedValue(user1.getAddress());
            console.log("collateral --  : ", ethers.formatUnits(col, 18))

            const user2Balance = await mockWETH.balanceOf(user2.getAddress());
            console.log("User2 WETH balance:", ethers.formatUnits(user2Balance, 18))

            // User2 liquidates User1
            await mockUSDC.connect(user2).approve(lending.getAddress(), borrowAmount);

            const cTokenAddress = await lending.s_tokenToCToken(mockWETH.getAddress());
            const cTokenBalance = await mockWETH.balanceOf(cTokenAddress);
            console.log("CToken balance before liquidation:", ethers.formatUnits(cTokenBalance, 18));

            await expect(
                lending
                    .connect(user2)
                    .liquidate(user1.address, mockUSDC.getAddress(), mockWETH.getAddress())
            ).to.emit(lending, "Liquidate");

            const user21Balance = await mockWETH.balanceOf(user2.getAddress());
            console.log("User2 WETH balance:", ethers.formatUnits(user21Balance, 18));

            const br1 = await lending.connect(user1).getAccountBorrowedValue(user1.getAddress());
            console.log("borrow --  : ", ethers.formatUnits(br1, 18))
            const col1 = await lending.connect(user1).getAccountBorrowedValue(user1.getAddress());
            console.log("collateral --  : ", ethers.formatUnits(col1, 18))
        })

        it("Should not allow liquidation of healthy positions", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(
                deployLendingFixture
            );

            await depositInitialLiquidity(user1, user2, lending, mockUSDC, mockWETH);

            // Setup: User1 deposits collateral and borrows
            const collateralAmount = ethers.parseUnits("1", 18);
            const borrowAmount = ethers.parseUnits("1000", 18);

            await mockWETH.connect(user1).approve(lending.getAddress(), collateralAmount);
            await lending.connect(user1).deposit(mockWETH.getAddress(), collateralAmount);
            await lending.connect(user1).borrow(mockUSDC.getAddress(), borrowAmount);

            // Try to liquidate healthy position
            await expect(
                lending
                    .connect(user2)
                    .liquidate(user1.address, mockUSDC.getAddress(), mockWETH.getAddress())
            ).to.be.revertedWithCustomError(lending, "AccountCannotBeLiquidated");
        });
    });

    describe("Health Factor", function () {
        it("Should correctly calculate health factor", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(
                deployLendingFixture
            );
            await depositInitialLiquidityBySecondUser(user2, lending, mockUSDC, mockWETH);

            // Deposit 1 WETH ($2000)
            await deposit(user1, lending, mockWETH, "1");
            // Borrow 1000 USDC ($1000)
            await borrow(user1, lending, mockUSDC, "1000");

            const healthFactor = await lending.healthFactor(user1.address);
            console.log("current health Factor is ", healthFactor);
            // Health factor should be 1.5 (accounting for 75% LTV) would be 150 0000 0000
            expect(healthFactor).to.be.above(ethers.parseUnits("140", 8));
            expect(healthFactor).to.be.below(ethers.parseUnits("160", 8));
        });
    });

    describe("Lending Protocol Scenarios", function () {
        async function calculateAPY(startAmount, endAmount) {
            return ((Number(endAmount) - Number(startAmount)) / Number(startAmount) * 100).toFixed(2);
        }

        it("Scenario 1: Lender deposits USDC and earns interest for 1 year", async function () {
            console.log("\nScenario 1: Lender earnings over 1 year");
            console.log("----------------------------------------");
            const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(deployLendingFixture);

            const cTokenAddress = await lending.s_tokenToCToken(mockUSDC.getAddress());
            const cToken = await ethers.getContractAt("CToken", cTokenAddress);

            // User1 deposits 10,000 USDC as a lender
            console.log("User1 deposits 10,000 USDC:");
            await deposit(user1, lending, mockUSDC, "10000");
            console.log("User2 deposits 5 WETH:");
            await deposit(user2, lending, mockWETH, "8");
            const firstRate1 = await cToken.exchangeRateStored();
            console.log("firstRate 11111111111111111", firstRate1)

            // User2 borrows 7,500 USDC (75% utilization)
            console.log("User2 borrows 5000 USDC:");
            await borrow(user2, lending, mockUSDC, "7500");

            const firstRate = await cToken.exchangeRateStored();
            console.log("firstRate", firstRate)
            // 162595212500000000000000

            await simulateBlocksTime(365)



            await cToken.accrueInterest();
            const secondRate = await cToken.exchangeRateStored();
            console.log("secondRate", secondRate)

            const borrows = await cToken.borrowBalanceCurrent(user2.address);
            console.log("borrows are ", borrows)

            const finalUnderlyingBalance = await cToken.balanceOfUnderlying(user1.address);
            const finalUnderlyingBalance2 = await cToken.balanceOfUnderlying(user2.address);
            const initialAmount = ethers.parseUnits("10000", 18);
            const apy = await calculateAPY(initialAmount, finalUnderlyingBalance);

            console.log("\nFinal Results:");
            console.log(`Initial Deposit: 10,000 USDC`);
            console.log(`Final Balance user1: ${ethers.formatUnits(finalUnderlyingBalance, 18)} USDC`);
            console.log(`Final Balance user2: ${ethers.formatUnits(finalUnderlyingBalance2, 18)} USDC`);
            console.log(`APY Earned: ${apy}%`);

            expect(finalUnderlyingBalance).to.be.gt(initialAmount);
        });

        it("Scenario 2: Borrower pays interest over 1 month", async function () {
            console.log("\nScenario 2: Borrowing costs over 1 month");
            console.log("----------------------------------------");

            const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(deployLendingFixture);
            await depositInitialLiquidityBySecondUser(user2, lending, mockUSDC, mockWETH);

            // User1 deposits 2 ETH as collateral (worth $4,000)
            console.log("User1 deposits 2 ETH as collateral:");
            await deposit(user1, lending, mockWETH, "2");

            // User1 borrows 2,000 USDC (50% LTV)
            console.log("\nUser1 borrows 2,000 USDC:");
            await borrow(user1, lending, mockUSDC, "2000");

            // Simulate 1 month (approximately 175,200 blocks)
            console.log("\nSimulating 1 month of borrowing...");
            await simulateBlocksTime(30)

            const cTokenAddress = await lending.s_tokenToCToken(mockUSDC.getAddress());
            const cToken = await ethers.getContractAt("CToken", cTokenAddress);
            await cToken.accrueInterest();

            // Get final borrow balance
            const finalBorrowBalance = await cToken.borrowBalanceCurrent(user1.address);
            const initialBorrowAmount = ethers.parseUnits("2000", 18);
            const borrowAPY = await calculateAPY(initialBorrowAmount, finalBorrowBalance);

            console.log("\nFinal Results:");
            console.log(`Initial Borrow: 2,000 USDC`);
            console.log(`Debt After 1 Month: ${ethers.formatUnits(finalBorrowBalance, 18)} USDC`);
            console.log(`Annualized Borrow Rate: ${borrowAPY}%`);

            expect(finalBorrowBalance).to.be.gt(initialBorrowAmount);
        });

        it("Scenario 3: Liquidation threshold test", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(deployLendingFixture);
            await depositInitialLiquidityBySecondUser(user2, lending, mockUSDC, mockWETH);

            console.log("\nScenario 3: Liquidation Test");
            console.log("----------------------------------------");

            // User1 deposits 1 ETH as collateral (worth $2,000)
            console.log("User1 deposits 1 ETH as collateral:");
            await deposit(user1, lending, mockWETH, "1");

            // User1 borrows 1,500 USDC (75% LTV)
            console.log("\nUser1 borrows 1,500 USDC (75% LTV):");
            await borrow(user1, lending, mockUSDC, "1500");

            // Simulate ETH price drop by 30%
            console.log("\nSimulating 30% ETH price drop...");
            const wethPriceFeed = await ethers.getContractAt(
                "MockV3Aggregator",
                await lending.s_tokenToPriceFeed(mockWETH.getAddress())
            );
            await wethPriceFeed.updateAnswer(140000000000); // $1,400

            // Check health factor
            const healthFactor = await lending.healthFactor(user1.address);
            console.log("\nPost-Price Drop Status:");
            console.log(`Health Factor: ${ethers.formatUnits(healthFactor, 8)}`);
            console.log(`Collateral Value: $1,400`);
            console.log(`Borrow Value: $1,500`);
            console.log(`Liquidation Eligible: ${healthFactor < ethers.parseUnits("1", 8)}`);

            // Prepare liquidator (user2) and attempt liquidation
            if (healthFactor < ethers.parseUnits("1", 8)) {
                await mockUSDC.connect(user2).approve(lending.getAddress(), ethers.parseUnits("1500", 18));
                await lending.connect(user2).liquidate(
                    user1.address,
                    mockUSDC.getAddress(),
                    mockWETH.getAddress()
                );
                console.log("\nPosition successfully liquidated");
            }
        });

        it("Scenario 4: Multi-user lending simulation over 6 months", async function () {
            const { lending, mockUSDC, user1, user2 } = await loadFixture(deployLendingFixture);

            console.log("\nScenario 4: Multi-user lending over 6 months");
            console.log("----------------------------------------");

            // User1 deposits 50,000 USDC
            console.log("User1 deposits 50,000 USDC:");
            await deposit(user1, lending, mockUSDC, "5000");

            // User2 deposits 30,000 USDC
            console.log("\nUser2 deposits 30,000 USDC:");
            await deposit(user2, lending, mockUSDC, "3000");

            // User2 borrows 56,000 USDC (70% utilization)
            console.log("\nUser2 borrows 56,000 USDC (75% utilization):");
            await borrow(user2, lending, mockUSDC, "1700");

            // Simulate 6 months
            console.log("Simulating half year of lending...");
            await simulateBlocksTime(183)


            const cTokenAddress = await lending.s_tokenToCToken(mockUSDC.getAddress());
            const cToken = await ethers.getContractAt("CToken", cTokenAddress);
            await cToken.accrueInterest();

            await lending.connect(user2).withdraw(mockUSDC.getAddress(), ethers.parseUnits("1", 18));

            // Calculate returns for both users
            const user1FinalBalance = await cToken.balanceOfUnderlying(user1.address);
            const user2FinalBalance = await cToken.balanceOfUnderlying(user2.address);

            const user1APY = await calculateAPY(ethers.parseUnits("5000", 18), user1FinalBalance);
            const user2APY = await calculateAPY(ethers.parseUnits("3000", 18), user2FinalBalance);

            console.log("\nFinal Results After 6 Months:");
            console.log("\nUser 1:");
            console.log(`Initial Deposit: 5,000 USDC`);
            console.log(`Final Balance: ${ethers.formatUnits(user1FinalBalance, 18)} USDC`);
            console.log(`APY: ${user1APY}%`);
            console.log("\nUser 2:");
            console.log(`Initial Deposit: 3,000 USDC`);
            console.log(`Final Balance: ${ethers.formatUnits(user2FinalBalance, 18)} USDC`);
            console.log(`APY: ${user2APY}%`);
        });
        it("Scenario 5: Multi-user lending simulation over 6 months without claiming staking rewards", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(deployLendingFixture);

            console.log("\nScenario 5: Multi-user lending over 6 months");
            console.log("----------------------------------------");

            console.log("User1 deposits 5000 USDC:");
            await deposit(user1, lending, mockUSDC, "5000");
            await deposit(user2, lending, mockWETH, "1");

            console.log("\nUser2 borrows 1000 USDC:");
            await borrow(user2, lending, mockUSDC, "1000");

            // Simulate 6 months
            console.log("Simulating half year of lending...");
            await simulateBlocksTime(183);

            const cTokenAddress = await lending.s_tokenToCToken(mockUSDC.getAddress());
            const cToken = await ethers.getContractAt("CToken", cTokenAddress);
            await cToken.accrueInterest();

            // Calculate final balances and APY
            const user1FinalBalance = await cToken.balanceOfUnderlying(user1.address);
            const user1APY = await calculateAPY(ethers.parseUnits("5000", 18), user1FinalBalance);

            // Calculate User 2's borrowing cost
            const user2FinalBorrowBalance = await cToken.borrowBalanceCurrent(user2.address);
            const user2BorrowAPY = await calculateAPY(ethers.parseUnits("1000", 18), user2FinalBorrowBalance);

            // Calculate the difference between User 2's borrowing cost and User 1's interest earned
            const interestDifference = ethers.formatUnits(user1FinalBalance, 18) - 4000 - ethers.formatUnits(user2FinalBorrowBalance, 18);

            console.log("\nFinal Results After 6 Months:");
            console.log("\nUser 1:");
            console.log(`Initial Deposit: 5,000 USDC`);
            console.log(`Final Balance: ${ethers.formatUnits(user1FinalBalance, 18)} USDC`);
            console.log(`APY Earned: ${user1APY}%`);
            console.log("\nUser 2:");
            console.log(`Initial Borrow: 1,000 USDC`);
            console.log(`Debt After 6 Months: ${ethers.formatUnits(user2FinalBorrowBalance, 18)} USDC`);
            console.log(`Borrowing Cost: ${user2BorrowAPY}%`);
            console.log(`Interest Difference (User 2 - User 1): ${interestDifference} USD`);
            const apr = await cToken.getSupplyAPR();
            console.log(`apr is : ${ethers.formatUnits(apr, 18)} USDC`)
        });

        it("Scenario 6: Multi-user lending simulation over 6 months with claiming staking rewards", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2, usdcStaking } = await loadFixture(deployLendingFixture);

            console.log("\nScenario 5: Multi-user lending over 6 months");
            console.log("----------------------------------------");

            console.log("User1 deposits 5000 USDC:");
            await deposit(user1, lending, mockUSDC, "5000");
            await deposit(user2, lending, mockWETH, "1");

            console.log("\nUser2 borrows 1000 USDC:");
            // await borrow(user2, lending, mockUSDC, "1000");

            // Simulate 6 months
            console.log("Simulating half year of lending...");
            await simulateBlocksTime(183);

            const cTokenAddress = await lending.s_tokenToCToken(mockUSDC.getAddress());
            const cToken = await ethers.getContractAt("CToken", cTokenAddress);

            const stakingRewards = await usdcStaking.getPendingRewards(cTokenAddress)

            await cToken.claimAndUpdateRewards();
            await cToken.accrueInterest();

            // Calculate final balance and APY
            const user1FinalBalance = await cToken.balanceOfUnderlying(user1.address);
            const user1APY = await calculateAPY(ethers.parseUnits("5000", 18), user1FinalBalance);

            console.log("\nFinal Results After 6 Months:");
            console.log("\nUser 1:");
            console.log(`Initial Deposit: 5,000 USDC`);
            console.log(`Final Balance: ${ethers.formatUnits(user1FinalBalance, 18)} USDC`);
            console.log(`APY Earned: ${user1APY}%`);
            console.log(`Total Staking Rewards: ${ethers.formatUnits(stakingRewards, 18)} USDC`);
            const apr = await cToken.getSupplyAPR();
            console.log(`apr is : ${ethers.formatUnits(apr, 18)} USDC`);
        });


        it("Should calculate borrow rates correctly based on utilization", async function () {
            const { lending, mockUSDC } = await loadFixture(deployLendingFixture);
            const BLOCKS_PER_YEAR = 12102400
            // Get cToken instance
            const cTokenAddress = await lending.s_tokenToCToken(mockUSDC.getAddress());
            const cToken = await ethers.getContractAt("CToken", cTokenAddress);

            // Test scenarios with different utilization rates
            const scenarios = [
                { cash: "10000", borrows: "0", reserves: "0", description: "0% utilization" },
                { cash: "8000", borrows: "2000", reserves: "0", description: "20% utilization" },
                { cash: "5000", borrows: "5000", reserves: "0", description: "50% utilization" },
                { cash: "2500", borrows: "7500", reserves: "0", description: "75% utilization" },
                { cash: "1000", borrows: "9000", reserves: "0", description: "90% utilization" },
                { cash: "0", borrows: "10000", reserves: "0", description: "100% utilization" },
                // Test with reserves
                { cash: "8000", borrows: "2000", reserves: "1000", description: "20% utilization with reserves" },
                { cash: "5000", borrows: "5000", reserves: "1000", description: "50% utilization with reserves" }
            ];

            console.log("\nBorrow Rate Scenarios:");
            console.log("----------------------------------------");

            for (const scenario of scenarios) {
                const cash = ethers.parseUnits(scenario.cash, 18);
                const borrows = ethers.parseUnits(scenario.borrows, 18);
                const reserves = ethers.parseUnits(scenario.reserves, 18);

                const borrowRate = await cToken.getBorrowRate(cash, borrows, reserves);
                const annualRate = borrowRate * BigInt(BLOCKS_PER_YEAR);

                console.log(`\n${scenario.description}:`);
                console.log(`Cash: ${scenario.cash} USDC`);
                console.log(`Borrows: ${scenario.borrows} USDC`);
                console.log(`Reserves: ${scenario.reserves} USDC`);
                console.log(`Borrow Rate per Block: ${ethers.formatUnits(borrowRate, 18)}`);
                console.log(`Annual Borrow Rate: ${ethers.formatUnits(annualRate, 16)}%`);

                // Verify rate is within expected bounds
                expect(borrowRate).to.be.gte(0);

                // For 0% utilization, should return base rate
                if (borrows == 0) {
                    const baseRatePerBlock = ethers.parseUnits("0.01", 18) / BigInt(BLOCKS_PER_YEAR);
                    expect(borrowRate).to.equal(baseRatePerBlock);
                }

                // For 100% utilization, should return max rate (base + multiplier)
                if (cash == 0 && borrows > 0) {
                    const maxRatePerBlock = (ethers.parseUnits("0.11", 18)) / BigInt(BLOCKS_PER_YEAR); // 1% base + 10% multiplier
                    expect(borrowRate).to.equal(maxRatePerBlock);
                }
            }

            // Test that rate increases with utilization
            const lowUtilRate = await cToken.getBorrowRate(
                ethers.parseUnits("8000", 18),
                ethers.parseUnits("2000", 18),
                0
            );

            const highUtilRate = await cToken.getBorrowRate(
                ethers.parseUnits("2000", 18),
                ethers.parseUnits("8000", 18),
                0
            );

            expect(highUtilRate).to.be.gt(lowUtilRate, "Higher utilization should result in higher rate");
        });
    });


    describe("Repay Function", function () {
        it("Should allow full repayment of borrowed amount", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(deployLendingFixture);

            await depositInitialLiquidityBySecondUser(user2, lending, mockUSDC, mockWETH);
            // User1 deposits WETH as collateral
            await deposit(user1, lending, mockWETH, "2"); // $4000 collateral

            // User1 borrows USDC
            const borrowAmount = "2000"; // $2000
            await borrow(user1, lending, mockUSDC, borrowAmount);

            // Check initial borrow balance
            const cTokenAddress = await lending.s_tokenToCToken(mockUSDC.getAddress());
            const cToken = await ethers.getContractAt("CToken", cTokenAddress);
            const initialBorrowBalance = await cToken.borrowBalanceCurrent(user1.address);

            // Mint USDC for repayment and approve
            await mockUSDC.mint(user1.address, ethers.parseUnits(borrowAmount, 18));
            await mockUSDC.connect(user1).approve(lending.getAddress(), ethers.parseUnits(borrowAmount, 18));

            // Full repayment
            await lending.connect(user1).repay(mockUSDC.getAddress(), ethers.parseUnits(borrowAmount, 18));

            // Check final borrow balance
            const finalBorrowBalance = await cToken.borrowBalanceCurrent(user1.address);

            console.log("Repay Full Amount Test:");
            console.log(`Initial Borrow Balance: ${ethers.formatUnits(initialBorrowBalance, 18)} USDC`);
            console.log(`Repayment Amount: ${borrowAmount} USDC`);
            console.log(`Final Borrow Balance: ${ethers.formatUnits(finalBorrowBalance, 18)} USDC`);

            expect(finalBorrowBalance).to.be.lt(initialBorrowBalance);
            expect(finalBorrowBalance).to.be.closeTo(0, ethers.parseUnits("0.1", 18));
        });

        it("Should allow partial repayment of borrowed amount", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(deployLendingFixture);
            await depositInitialLiquidityBySecondUser(user2, lending, mockUSDC, mockWETH);

            await deposit(user1, lending, mockWETH, "2")
            await borrow(user1, lending, mockUSDC, "2000")

            // Check initial borrow balance
            const cTokenAddress = await lending.s_tokenToCToken(mockUSDC.getAddress());
            const cToken = await ethers.getContractAt("CToken", cTokenAddress);
            const initialBorrowBalance = await cToken.borrowBalanceCurrent(user1.address);

            // Partial repayment amount
            const partialRepayAmount = ethers.parseUnits("1000", 18);

            // Approve and repay
            await mockUSDC.connect(user1).approve(lending.getAddress(), partialRepayAmount);
            await lending.connect(user1).repay(mockUSDC.getAddress(), partialRepayAmount);

            // Check final borrow balance
            const finalBorrowBalance = await cToken.borrowBalanceCurrent(user1.address);

            console.log("Repay Partial Amount Test:");
            console.log(`Initial Borrow Balance: ${ethers.formatUnits(initialBorrowBalance, 18)} USDC`);
            console.log(`Partial Repayment Amount: ${ethers.formatUnits(partialRepayAmount, 18)} USDC`);
            console.log(`Final Borrow Balance: ${ethers.formatUnits(finalBorrowBalance, 18)} USDC`);

            // Use BigNumber methods for calculations
            const expectedFinalBalance = initialBorrowBalance - partialRepayAmount;
            expect(finalBorrowBalance).to.be.lt(initialBorrowBalance);
            expect(finalBorrowBalance).to.be.closeTo(
                expectedFinalBalance,
                ethers.parseUnits("0.1", 18) // Small margin for rounding errors
            );
        });


        it("Should revert when trying to repay with zero amount", async function () {
            const { lending, mockUSDC, user1 } = await loadFixture(deployLendingFixture);

            // Attempt to repay with zero amount
            await expect(
                lending.connect(user1).repay(mockUSDC.getAddress(), 0)
            ).to.be.revertedWithCustomError(lending, "NeedsMoreThanZero");
        });

        it("Should revert when trying to repay with non-allowed token", async function () {
            const { lending, user1 } = await loadFixture(deployLendingFixture);

            // Create a mock token that is not allowed
            const MockERC20Factory = await ethers.getContractFactory("MockERC20");
            const invalidToken = await MockERC20Factory.deploy("Invalid Token", "INVALID");
            await invalidToken.waitForDeployment();

            // Attempt to repay with invalid token
            await expect(
                lending.connect(user1).repay(
                    await invalidToken.getAddress(),
                    ethers.parseUnits("100", 18)
                )
            ).to.be.revertedWithCustomError(lending, "TokenNotAllowed");
        });

        it("Should accrue interest before repayment", async function () {
            const { lending, mockUSDC, mockWETH, user2, user1 } = await loadFixture(deployLendingFixture);

            await depositInitialLiquidityBySecondUser(user2, lending, mockUSDC, mockWETH);

            // User1 deposits WETH as collateral
            await deposit(user1, lending, mockWETH, "2"); // $4000 collateral
            await borrow(user1, lending, mockUSDC, "2000");

            await simulateBlocksTime(365);
            // Check initial borrow balance (including interest)
            const cTokenAddress = await lending.s_tokenToCToken(mockUSDC.getAddress());
            const cToken = await ethers.getContractAt("CToken", cTokenAddress);
            await cToken.accrueInterest();
            const initialBorrowBalance = await cToken.borrowBalanceCurrent(user1.address);

            // Mint USDC for repayment (including interest)
            await mockUSDC.connect(user1).approve(lending.getAddress(), initialBorrowBalance);
            await lending.connect(user1).repay(mockUSDC.getAddress(), initialBorrowBalance);

            // Check final borrow balance
            const finalBorrowBalance = await cToken.borrowBalanceCurrent(user1.address);

            console.log("Repay with Interest Test:");
            console.log(`Initial Borrow Balance: ${ethers.formatUnits(initialBorrowBalance, 18)} USDC`);
            console.log(`Repayment Amount: ${ethers.formatUnits(initialBorrowBalance, 18)} USDC`);
            console.log(`Final Borrow Balance: ${ethers.formatUnits(finalBorrowBalance, 18)} USDC`);
            expect(finalBorrowBalance).to.be.closeTo(0, ethers.parseUnits("0.1", 18));
        });
    });

    describe("Withdraw Tests", function () {
        describe("withdraw", function () {
            it("Should allow withdrawal of deposited tokens", async function () {
                const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(deployLendingFixture);

                await depositInitialLiquidityBySecondUser(user2, lending, mockUSDC, mockWETH);

                await deposit(user1, lending, mockUSDC, "1000");

                // Get cToken instance
                const cTokenAddress = await lending.s_tokenToCToken(await mockUSDC.getAddress());
                const CToken = await ethers.getContractFactory("CToken");
                const cToken = CToken.attach(cTokenAddress);

                // Check initial cToken balance
                const initialCTokenBalance = await cToken.balanceOf(user1.address);
                console.log("Initial cToken balance :", ethers.formatUnits(initialCTokenBalance, 18));

                // Withdraw all deposited tokens
                await lending.connect(user1).withdraw(mockUSDC.getAddress(), initialCTokenBalance);

                // Check final balances
                const finalCTokenBalance = await cToken.balanceOf(user1.address);
                const finalTokenBalance = await mockUSDC.balanceOf(user1.address);

                console.log("Final cToken balance:", ethers.formatUnits(finalCTokenBalance, 18));
                console.log("Final USDC balance:", ethers.formatUnits(finalTokenBalance, 18));

                expect(finalCTokenBalance).to.equal(0);
                expect(finalTokenBalance).to.be.closeTo(
                    ethers.parseUnits("10000", 18),
                    ethers.parseUnits("0.1", 18)
                );
            });

            it("Should fail when withdrawal would make account insolvent", async function () {
                const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(deployLendingFixture);

                // Add liquidity to avoid liquidity problems
                await depositInitialLiquidityBySecondUser(user2, lending, mockUSDC, mockWETH);

                // Initial deposits for user1
                console.log("\nDepositing collateral:");
                await deposit(user1, lending, mockWETH, "1");     // $2000 WETH

                // Borrow against collateral
                console.log("\nBorrowing USDC:");
                await borrow(user1, lending, mockUSDC, "1000"); // $1000 USDC

                // Get user's health factor before withdrawal attempt
                const healthFactorBefore = await lending.healthFactor(user1.address);
                console.log("\nHealth factor before withdrawal attempt:", ethers.formatUnits(healthFactorBefore, 8));

                // Try to withdraw all WETH
                const cTokenAddress = await lending.s_tokenToCToken(mockWETH.getAddress());
                const CToken = await ethers.getContractFactory("CToken");
                const cToken = CToken.attach(cTokenAddress);
                const cTokenBalance = await cToken.balanceOf(user1.address);

                console.log("Attempting to withdraw all WETH collateral...");
                await expect(
                    lending.connect(user1).withdraw(mockWETH.getAddress(), cTokenBalance)
                ).to.be.revertedWithCustomError(lending, "InsufficientHealthFactor");

                const healthFactorAfter = await lending.healthFactor(user1.address);
                console.log("Health factor after failed withdrawal:", ethers.formatUnits(healthFactorAfter, 8));
            });

            it("Should allow partial withdrawal while maintaining solvency", async function () {
                const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(deployLendingFixture);

                // Add liquidity to avoid liquidity problems
                await depositInitialLiquidityBySecondUser(user2, lending, mockUSDC, mockWETH);

                // Initial deposits for user1
                console.log("\nDepositing collateral:");
                await deposit(user1, lending, mockUSDC, "2000");  // $2000 USDC
                await deposit(user1, lending, mockWETH, "1");     // $2000 WETH

                // Borrow against collateral
                console.log("\nBorrowing USDC:");
                await borrow(user1, lending, mockUSDC, "1000"); // $1000 USDC

                // Get cToken instance and balance
                const cTokenAddress = await lending.s_tokenToCToken(await mockWETH.getAddress());
                const CToken = await ethers.getContractFactory("CToken");
                const cToken = CToken.attach(cTokenAddress);
                const cTokenBalance = await cToken.balanceOf(user1.address);

                // Try to withdraw half of WETH
                const halfCTokenBalance = cTokenBalance / 2n;
                console.log("\nAttempting to withdraw half of WETH collateral...");

                const healthFactorBefore = await lending.healthFactor(user1.address);
                console.log("Health factor before partial withdrawal:", ethers.formatUnits(healthFactorBefore, 8));

                await lending.connect(user1).withdraw(await mockWETH.getAddress(), halfCTokenBalance);

                const healthFactorAfter = await lending.healthFactor(user1.address);
                console.log("Health factor after partial withdrawal:", ethers.formatUnits(healthFactorAfter, 8));

                // Verify the withdrawal was successful
                const finalCTokenBalance = await cToken.balanceOf(user1.address);
                expect(finalCTokenBalance).to.equal(cTokenBalance - halfCTokenBalance);
                console.log("Remaining cToken balance:", ethers.formatUnits(finalCTokenBalance, 18));
            });

            it("Should emit Withdraw event with correct parameters", async function () {
                const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(deployLendingFixture);

                // Add liquidity to avoid liquidity problems
                await depositInitialLiquidityBySecondUser(user2, lending, mockUSDC, mockWETH);

                // Initial deposit
                console.log("\nDepositing USDC:");
                await deposit(user1, lending, mockUSDC, "1000");

                // Get cToken balance
                const cTokenAddress = await lending.s_tokenToCToken(await mockUSDC.getAddress());
                const CToken = await ethers.getContractFactory("CToken");
                const cToken = CToken.attach(cTokenAddress);
                const cTokenBalance = await cToken.balanceOf(user1.address);

                console.log("cToken balance before withdrawal:", ethers.formatUnits(cTokenBalance, 18));

                // Verify event emission
                const withdrawTx = lending.connect(user1).withdraw(await mockUSDC.getAddress(), cTokenBalance);

                await expect(withdrawTx)
                    .to.emit(lending, "Withdraw")

                console.log("Withdrawal successful, event emitted");
            });
        });
    });

    describe("Liquidity Management", function () {
        it("should successfully swap with sufficient liquidity", async function () {
            const { mockRouter, mockUSDC, mockWETH, user1 } = await loadFixture(deployLendingFixture);

            // Now perform a swap
            const swapAmount = ethers.parseUnits("1", 18); // Swap 1 ETH
            await mockWETH.connect(user1).approve(mockRouter.getAddress(), swapAmount);

            const params = {
                tokenIn: await mockWETH.getAddress(),
                tokenOut: await mockUSDC.getAddress(),
                fee: 3000,
                recipient: user1.address,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                amountIn: swapAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            };

            await expect(mockRouter.connect(user1).exactInputSingle(params)).to.not.be.reverted;

            // Check user received 2000 USDC
            const expectedUSDC = ethers.parseUnits("2000", 18);
            expect(await mockUSDC.balanceOf(user1.address))
                .to.equal(ethers.parseUnits("12000", 18)); // Initial 10000 + 2000 from swap
        });
    });

    describe("checkAndLiquidatePositions", function () {
        it("Should liquidate unhealthy positions when checkAndLiquidatePositions is called", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2, wethPriceFeed } = await loadFixture(deployLendingFixture);

            await depositInitialLiquidityBySecondUser(user2, lending, mockUSDC, mockWETH);
            // User1 deposits collateral and borrows
            await deposit(user1, lending, mockWETH, "1"); // 1 WETH = $2000
            await borrow(user1, lending, mockUSDC, "1000"); // $1000 USDC
            await borrow(user2, lending, mockUSDC, "10"); // $1000 USDC

            // Simulate a price drop to make User1's position unhealthy
            await wethPriceFeed.updateAnswer(100000000000); // $1400

            // Check initial borrow balance of user1
            const initialBorrowBalanceUser1 = await lending.getAccountBorrowedValue(user1.address);
            expect(initialBorrowBalanceUser1).to.be.gt(0);

            console.log("checkAndLiquidatePositions -----------")
            // Call checkAndLiquidatePositions
            await lending.checkAndLiquidatePositions();

            // Check that User1's borrow balance is now zero
            const finalBorrowBalanceUser1 = await lending.getAccountBorrowedValue(user1.address);
            expect(finalBorrowBalanceUser1).to.equal(0);

            console.log("user2BorrowBalance -----------")
            // Check that User2's borrow balance remains intact
            const user2BorrowBalance = await lending.getAccountBorrowedValue(user2.address);
            expect(user2BorrowBalance).to.be.gt(0); // Ensure user2 still has a borrow balance
        });

        it("Should not liquidate healthy positions when checkAndLiquidatePositions is called", async function () {
            const { lending, mockUSDC, mockWETH, user1, user2 } = await loadFixture(deployLendingFixture);

            // User1 deposits collateral and borrows
            await deposit(user1, lending, mockWETH, "1"); // 1 WETH = $2000
            await deposit(user2, lending, mockUSDC, "2000"); // $1500 USDC

            await borrow(user1, lending, mockUSDC, "1000"); // $1000 USDC
            const finalBorrowBalanceUser11 = await lending.getAccountBorrowedValue(user1.address);
            console.log("user1BorrowBalance1 -----------", finalBorrowBalanceUser11)

            // User2 deposits collateral and borrows
            await borrow(user2, lending, mockWETH, "0.5"); // 1 WETH = $2000
            const finalBorrowBalanceUser12 = await lending.getAccountBorrowedValue(user1.address);
            console.log("user2BorrowBalance2 -----------", finalBorrowBalanceUser12)

            // Call checkAndLiquidatePositions without changing prices
            await lending.checkAndLiquidatePositions();

            // Check that User1's borrow balance is still greater than zero
            const finalBorrowBalanceUser1 = await lending.getAccountBorrowedValue(user1.address);
            console.log("user1BorrowBalance -----------", finalBorrowBalanceUser1)
            expect(finalBorrowBalanceUser1).to.be.gt(0);

            // Check that User2's borrow balance remains intact
            const user2BorrowBalance = await lending.getAccountBorrowedValue(user2.address);
            console.log("user2BorrowBalance -----------", user2BorrowBalance)
            expect(user2BorrowBalance).to.be.gt(0); // Ensure user2 still has a borrow balance
        });
    });

    describe("Borrow Function Second Part", function () {
        async function setupBorrowTest() {
            const fixture = await loadFixture(deployLendingFixture);
            // Deposit initial liquidity
            await depositInitialLiquidity(
                fixture.user1,
                fixture.user2,
                fixture.lending,
                fixture.mockUSDC,
                fixture.mockWETH
            );
            return fixture;
        }

        async function logBorrowState(fixture, user) {
            const { lending, mockUSDC, mockWETH } = fixture;

            const borrowBalance = await lending.getAccountBorrowedValue(user.address);
            console.log("Current Borrow Balance:", borrowBalance.toString());

            const collateralValue = await lending.getAccountCollateralValue(user.address);
            console.log("Current Collateral Value:", collateralValue.toString());

            const healthFactor = await lending.healthFactor(user.address);
            console.log("Health Factor:", healthFactor.toString());
        }

        it("Should allow borrowing up to 75% of collateral value USDC", async function () {
            const fixture = await setupBorrowTest();
            const { lending, mockUSDC, user1 } = fixture;

            // Calculate maximum borrow amount (75% of 1 WETH worth $2000 = $1500)
            const borrowAmount = ethers.parseUnits("1500", 18);

            // Log initial state
            console.log("--- Before Borrow ---");
            await logBorrowState(fixture, user1);

            await lending.connect(user1).borrow(mockUSDC.getAddress(), borrowAmount);

            // Log state after borrow
            console.log("--- After Borrow ---");
            await logBorrowState(fixture, user1);

            // Verify borrow was successful
            const cTokenAddress = await lending.s_tokenToCToken(mockUSDC.getAddress());
            const cToken = await ethers.getContractAt("CToken", cTokenAddress);
            const borrowBalance = await cToken.borrowBalanceCurrent(user1.address);

            expect(borrowBalance).to.equal(borrowAmount);
        });

        it("Should allow borrowing up to 75% of collateral value WETH", async function () {
            const fixture = await setupBorrowTest();
            const { lending, mockWETH, user2 } = fixture;

            // Calculate maximum borrow amount (75% of 1 WETH worth $2000 = $1500)
            const borrowAmount = ethers.parseUnits("0.75", 18);

            // Log initial state
            console.log("--- Before Borrow ---");
            await logBorrowState(fixture, user2);

            await lending.connect(user2).borrow(mockWETH.getAddress(), borrowAmount);

            // Log state after borrow
            console.log("--- After Borrow ---");
            await logBorrowState(fixture, user2);

            // Verify borrow was successful
            const cTokenAddress = await lending.s_tokenToCToken(mockWETH.getAddress());
            const cToken = await ethers.getContractAt("CToken", cTokenAddress);
            const borrowBalance = await cToken.borrowBalanceCurrent(user2.address);

            expect(borrowBalance).to.equal(borrowAmount);
        });

        it("Should not allow borrowing up to 75% of collateral value WETH", async function () {
            const fixture = await setupBorrowTest();
            const { lending, mockWETH, user2 } = fixture;

            // Calculate maximum borrow amount (75% of 1 WETH worth $2000 = $1500)
            const borrowAmount = ethers.parseUnits("0.7500000000001", 18);
            await expect(
                lending.connect(user2).borrow(mockWETH.getAddress(), borrowAmount)
            ).to.be.revertedWithCustomError(lending, "InsufficientHealthFactor");
        });

        it("Should prevent borrowing above collateral limit", async function () {
            const fixture = await setupBorrowTest();
            const { lending, mockUSDC, user1 } = fixture;

            // Try to borrow more than 75% of collateral
            const borrowAmount = ethers.parseUnits("1600", 18); // $1600 > 75% of $2000

            await mockUSDC.connect(user1).approve(lending.getAddress(), borrowAmount);

            // Update to use custom error
            await expect(
                lending.connect(user1).borrow(mockUSDC.getAddress(), borrowAmount)
            ).to.be.revertedWithCustomError(lending, "InsufficientHealthFactor");
        });

        it("Should update borrow balances correctly after interest accrual", async function () {
            const fixture = await setupBorrowTest();
            const { lending, mockUSDC, user1, user2 } = fixture;

            // Borrow some USDC
            const borrowAmount = ethers.parseUnits("1000", 18);
            await borrow(user1, lending, mockUSDC, "1000");

            // Log initial borrow state
            console.log("--- Initial Borrow State ---");
            await logBorrowState(fixture, user1);

            // Mine some blocks to accrue interest
            await ethers.provider.send("hardhat_mine", ["0x100"]); // Mine 256 blocks

            await borrow(user2, lending, mockUSDC, "1")

            // Log state after interest accrual
            console.log("--- After Interest Accrual ---");
            await logBorrowState(fixture, user1);
            // Verify borrow balance has increased
            const newBorrowBalance = await lending.getAccountBorrowedValue(user1.address);
            expect(newBorrowBalance).to.be.gt(borrowAmount);
        });

        it("Should fail when borrowing non-allowed token", async function () {
            const fixture = await setupBorrowTest();
            const { lending, user1 } = fixture;

            // Deploy a new token that's not allowed
            const MockERC20Factory = await ethers.getContractFactory("MockERC20");
            const nonAllowedToken = await MockERC20Factory.deploy("Non Allowed", "NAT");
            await nonAllowedToken.waitForDeployment();

            await expect(
                lending.connect(user1).borrow(nonAllowedToken.getAddress(), 100)
            ).to.be.revertedWithCustomError(lending, "TokenNotAllowed");
        });

        it("Should fail when borrowing zero amount", async function () {
            const fixture = await setupBorrowTest();
            const { lending, mockUSDC, user1 } = fixture;

            await expect(
                lending.connect(user1).borrow(mockUSDC.getAddress(), 0)
            ).to.be.revertedWithCustomError(lending, "NeedsMoreThanZero");
        });

        it("Should handle multiple borrows up to collateral limit", async function () {
            const fixture = await setupBorrowTest();
            const { lending, mockUSDC, user1 } = fixture;

            // First borrow
            const firstBorrowAmount = ethers.parseUnits("500", 18);
            await mockUSDC.connect(user1).approve(lending.getAddress(), firstBorrowAmount);
            await lending.connect(user1).borrow(mockUSDC.getAddress(), firstBorrowAmount);

            console.log("--- After First Borrow ---");
            await logBorrowState(fixture, user1);

            // Second borrow
            const secondBorrowAmount = ethers.parseUnits("500", 18);
            await mockUSDC.connect(user1).approve(lending.getAddress(), secondBorrowAmount);
            await lending.connect(user1).borrow(mockUSDC.getAddress(), secondBorrowAmount);

            console.log("--- After Second Borrow ---");
            await logBorrowState(fixture, user1);

            const totalBorrowed = await lending.getAccountBorrowedValue(user1.address);

            // Verify total borrowed amount
            expect(totalBorrowed).to.be.above(ethers.parseUnits("1000", 18));
            expect(totalBorrowed).to.be.below(ethers.parseUnits("1001", 18));
        });

        it("Should track borrow balances separately for different users", async function () {
            const fixture = await setupBorrowTest();
            const { lending, mockUSDC, mockWETH, user1, user2 } = fixture;

            // Setup collateral for user2
            await deposit(user2, lending, mockWETH, "1");

            // User1 borrows
            await borrow(user1, lending, mockUSDC, "500");
            // Mine some blocks to accrue interest
            await ethers.provider.send("hardhat_mine", ["0x100"]); // Mine 256 blocks
            // User2 borrows
            await borrow(user2, lending, mockUSDC, "750");

            // Mine some blocks to accrue interest
            await ethers.provider.send("hardhat_mine", ["0x100"]); // Mine 256 blocks
            // Setup collateral for user2
            await deposit(user1, lending, mockUSDC, "1");

            console.log("--- User1 Borrow State ---");
            await logBorrowState(fixture, user1);
            console.log("--- User2 Borrow State ---");
            await logBorrowState(fixture, user2);


            // Verify separate balances
            const user2Balance = await lending.getAccountBorrowedValue(user2.address);
            const user1Balance = await lending.getAccountBorrowedValue(user1.address);
            console.log(user1Balance);
            console.log(user2Balance);

            expect(user1Balance).to.above(ethers.parseUnits("500", 18));
            expect(user1Balance).to.be.below(ethers.parseUnits("501", 18));
            expect(user2Balance).to.above(ethers.parseUnits("750", 18));
            expect(user2Balance).to.be.below(ethers.parseUnits("751", 18));
        });
    });

});