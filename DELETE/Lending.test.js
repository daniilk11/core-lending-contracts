const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Lending", function () {
    let lending, mockUSDC, mockETH, mockPriceFeed, mockDexRouter;
    let owner, user1;

    beforeEach(async function () {
        // Get signers
        [owner, user1] = await ethers.getSigners();

        // Deploy mock tokens
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        mockUSDC = await MockERC20.deploy("Mock USDC", "USDC");
        mockETH = await MockERC20.deploy("Mock ETH", "ETH");

        // Deploy mock price feed and router
        const MockChainlinkPriceFeed = await ethers.getContractFactory("MockChainlinkPriceFeed");
        const MockDexRouter = await ethers.getContractFactory("MockDexRouter");
        
        mockPriceFeed = await MockChainlinkPriceFeed.deploy();
        mockDexRouter = await MockDexRouter.deploy();

        // Deploy Lending contract
        const Lending = await ethers.getContractFactory("Lending");
        lending = await Lending.deploy(mockDexRouter.address);

        // Set up allowed tokens
        await lending.setAllowedToken(
            mockUSDC.address,
            mockPriceFeed.address,
            "cUSDC",
            "cUSDC"
        );
        await lending.setAllowedToken(
            mockETH.address,
            mockPriceFeed.address,
            "cETH",
            "cETH"
        );

        // Transfer some tokens to user1
        await mockUSDC.transfer(user1.address, ethers.parseUnits("10000", 18));
        await mockETH.transfer(user1.address, ethers.parseUnits("10", 18));
    });

    it("Should deposit and borrow correctly", async function () {
        // Connect as user1
        const user1Lending = lending.connect(user1);
        const amount = ethers.parseUnits("1000", 18);
        const borrowAmount = ethers.parseUnits("500", 18);

        // Approve and deposit USDC
        await mockUSDC.connect(user1).approve(lending.address, amount);
        await user1Lending.deposit(mockUSDC.address, amount);

        // Borrow ETH
        await user1Lending.borrow(mockETH.address, borrowAmount);

        // Repay ETH
        await mockETH.connect(user1).approve(lending.address, borrowAmount);
        await user1Lending.repay(mockETH.address, borrowAmount);

        // Get cToken address
        const cTokenAddress = await lending.s_tokenToCToken(mockUSDC.address);
        const CToken = await ethers.getContractFactory("CToken");
        const cToken = CToken.attach(cTokenAddress);

        // Withdraw USDC
        const cTokenBalance = await cToken.balanceOf(user1.address);
        await user1Lending.withdraw(mockUSDC.address, cTokenBalance);

        // Check final balances
        expect(await cToken.balanceOf(user1.address)).to.equal(0);
        expect(await mockUSDC.balanceOf(user1.address)).to.be.closeTo(
            ethers.parseUnits("10000", 18),
            ethers.parseUnits("1", 18)
        );
    });

    it("Should not allow borrow above health factor", async function () {
        const user1Lending = lending.connect(user1);
        const depositAmount = ethers.parseUnits("1000", 18);
        const largeAmount = ethers.parseUnits("2000", 18);

        // Deposit USDC
        await mockUSDC.connect(user1).approve(lending.address, depositAmount);
        await user1Lending.deposit(mockUSDC.address, depositAmount);

        // Try to borrow too much ETH
        await expect(
            user1Lending.borrow(mockETH.address, largeAmount)
        ).to.be.revertedWith("Borrow would put account below minimum health factor");
    });
});