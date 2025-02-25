const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CToken", function () {
    let cToken, usdc;

    beforeEach(async function () {
        const CToken = await ethers.getContractFactory("CToken");
        cToken = await CToken.deploy(usdc.address, "CToken USDC", "cUSDC");

        usdc = await ethers.getContractAt("IERC20", usdcAddress);
    });

    it("Should mint and redeem correctly", async function () {
        // Mint cToken
        await usdc.approve(cToken.address, 1000);
        await cToken.mint(user1, 1000);

        // Redeem cToken
        await cToken.redeem(user1, 1000);

        // Validate the state of the cToken
        expect(await cToken.totalSupply()).to.equal(0);
        expect(await usdc.balanceOf(user1)).to.equal(1000);
    });

    it("Should accrue interest correctly", async function () {
        // Mint cToken
        await usdc.approve(cToken.address, 1000);
        await cToken.mint(user1, 1000);

        // Increase block number to trigger interest accrual
        await ethers.provider.send("evm_increaseTime", [100000]);
        await ethers.provider.send("evm_mine", []);

        // Redeem cToken
        await cToken.redeem(user1, 1000);

        // Validate the state of the cToken
        expect(await cToken.totalSupply()).to.be.below(1000);
        expect(await usdc.balanceOf(user1)).to.be.above(1000);
    });
});