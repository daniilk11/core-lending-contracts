// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Staking Interface
 * @notice Interface for interacting with a staking contract
 */
interface IStaking {
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getPendingRewards(address user) external view returns (uint256);
    function getStakeInfo(address user) external view returns (
        uint256 stakedAmount,
        uint256 stakingTime,
        uint256 pendingRewards
    );
    function STAKING_APR() external view returns (uint256);
}

/**
 * @title CToken Contract
 * @notice A tokenized representation of deposits in the lending platform
 * @dev Implements ERC20 token standard with interest accrual mechanisms
 */
contract CToken is ERC20, Ownable {
    // Immutable variables
    IERC20 public immutable underlyingToken;  // The underlying ERC20 token being supplied
    IStaking public stakingContract;          // Contract for staking a portion of deposits

    // State variables
    uint256 public totalBorrows;              // Total amount of outstanding borrows
    uint256 public exchangeRateStored;        // Exchange rate between cToken and underlying (scaled by 1e18)
    uint256 public borrowIndex;               // Global borrow index for interest calculation
    uint256 public accrualBlockNumber;        // Last block when interest was accrued
    uint256 public loanToValue;               // Loan-to-value ratio used for collateral (in percent)
    uint256 public totalStakingRewards;       // Total rewards earned from staking
    uint256 public lastRewardsClaim;          // Timestamp of last rewards claim
    uint256 public totalReservesStored;       // Protocol reserves from interest

    // Constants for Base Sepolia network change for others
    uint256 public constant STAKING_PERCENTAGE = 50; // 50% of deposits go to staking
    uint256 public constant RESERVE_FACTOR = 0.1e18; // 10% of interest goes to reserves
    uint256 public constant BASE_RATE_PER_BLOCK = 826282390; // 1% base APY
    uint256 public constant MULTIPLIER_PER_BLOCK = 8262823902; // 10% at 100% utilization
    uint256 public constant BLOCKS_PER_YEAR = 12102400; // Estimated blocks per year

    // Mappings
    mapping(address => uint256) public accountBorrows;   // User's borrowed amount (scaled)
    mapping(address => uint256) public userInitialSupply; // Track initial deposit amount per user

    // Events
    event StakingWithdrawn(uint256 amount, string reason);
    event RewardsAddedToReserves(uint256 amount);
    event DynamicStakingAdjusted(uint256 amount, string reason);

    // Errors
    error TransferFailed(address token, address to, uint256 amount);
    error InterestAccumulationOverflow(uint256 currentBorrows, uint256 interestAccumulated);
    error InsufficientLiquidity(uint256 available, uint256 required);
    error BorrowIndexOverflow(uint256 newBorrowIndex, uint256 currentBorrowIndex);

    /**
     * @notice Contract constructor
     * @param _underlyingToken Address of the underlying ERC20 token
     * @param name Name of the cToken
     * @param symbol Symbol of the cToken
     * @param _stakingContract Address of the staking contract
     * @param owner Address of the contract owner
     */
    constructor(
        IERC20 _underlyingToken,
        string memory name,
        string memory symbol,
        address _stakingContract,
        address owner
    ) ERC20(name, symbol) Ownable(owner) {
        underlyingToken = _underlyingToken;
        stakingContract = IStaking(_stakingContract);
        exchangeRateStored = 1e18;  // Initial exchange rate: 1:1
        borrowIndex = 1e18;         // Initial borrow index
        loanToValue = 75;           // 75% LTV
        accrualBlockNumber = block.number;
        lastRewardsClaim = block.timestamp;

        // Approve staking contract to spend tokens
        underlyingToken.approve(_stakingContract, type(uint256).max);
    }

    /**
     * @notice Mint cTokens by supplying underlying tokens
     * @dev Also stakes a portion of supplied tokens based on STAKING_PERCENTAGE
     * @param user Address to receive the minted cTokens
     * @param underlyingAmount Amount of underlying tokens to supply
     * @return cTokenAmount Amount of cTokens minted
     */
    function mint(address user, uint256 underlyingAmount) external onlyOwner returns (uint256) {
        accrueInterest();

        // Stake tokens
        uint256 stakingAmount = (underlyingAmount * STAKING_PERCENTAGE) / 100;
        stakingContract.stake(stakingAmount);

        uint256 currentSupply = totalSupply();
        uint256 cTokenAmount;

        if (currentSupply > 0) {
            // Calculate cTokens based on current exchange rate
            cTokenAmount = underlyingAmount * 1e18 / exchangeRateStored;
        } else {
            // First deposit uses 1:1 ratio
            cTokenAmount = underlyingAmount;
        }

        _mint(user, cTokenAmount);
        userInitialSupply[user] += underlyingAmount;
        return cTokenAmount;
    }

    /**
     * @notice Borrow underlying tokens
     * @dev Updates borrow balances and transfers tokens to borrower
     * @param user Address of the borrower
     * @param borrowAmount Amount of underlying tokens to borrow
     */
    function borrow(address user, uint256 borrowAmount) external onlyOwner {
        accrueInterest();

        // Ensure we have enough liquidity for the borrow
        ensureLiquidity(borrowAmount);

        // Update borrower's debt (scaled by borrow index)
        accountBorrows[user] += ((borrowAmount * 1e18) + borrowIndex / 2) / borrowIndex;
        totalBorrows += borrowAmount;

        // Transfer tokens to borrower
        bool transferSuccess = underlyingToken.transfer(user, borrowAmount);
        if (!transferSuccess) revert TransferFailed(address(underlyingToken), user, borrowAmount);
    }

    /**
     * @notice Redeem cTokens for underlying tokens
     * @dev Burns cTokens and returns underlying tokens based on current exchange rate
     * @param user Address redeeming cTokens
     * @param cTokenAmount Amount of cTokens to redeem
     * @return underlyingAmount Amount of underlying tokens returned
     */
    function redeem(address user, uint256 cTokenAmount) external onlyOwner returns (uint256) {
        accrueInterest();
        claimAndUpdateRewards();

        // Calculate underlying amount based on exchange rate
        uint256 underlyingAmount = cTokenAmount * exchangeRateStored / 1e18;

        // Ensure we have enough liquidity for redemption
        ensureLiquidity(underlyingAmount);

        _burn(user, cTokenAmount);

        // Transfer underlying tokens to user
        bool transferSuccess = underlyingToken.transfer(user, underlyingAmount);
        if (!transferSuccess) revert TransferFailed(address(underlyingToken), user, underlyingAmount);

        // Update user's initial supply record (for reward calculation)
        userInitialSupply[user] = userInitialSupply[user] > underlyingAmount ? userInitialSupply[user] - underlyingAmount : 0;
        return underlyingAmount;
    }

    /**
     * @notice Repay borrowed tokens
     * @dev Reduces borrower's debt and updates total borrows
     * @param user Address of the borrower
     * @param repayAmount Amount of underlying tokens to repay
     */
    function repayBorrow(address user, uint256 repayAmount) external onlyOwner {
        accrueInterest();

        // Calculate the current borrow balance in actual token terms
        uint256 accountBorrowsInTokens = (accountBorrows[user] * borrowIndex) / 1e18;

        // Calculate the repayment in terms of principal (scaled)
        uint256 repayAmountScaled = (repayAmount * 1e18) / borrowIndex;

        if (repayAmount >= accountBorrowsInTokens) {
            // Full repayment
            totalBorrows = totalBorrows > accountBorrowsInTokens ? totalBorrows - accountBorrowsInTokens : 0;
            accountBorrows[user] = 0;
        } else {
            // Partial repayment
            totalBorrows = totalBorrows > repayAmount ? totalBorrows - repayAmount : 0;
            accountBorrows[user] = accountBorrows[user] - repayAmountScaled;
        }
    }

    /**
     * @notice Ensures contract has sufficient liquidity for an operation
     * @dev Withdraws from staking if needed to cover shortfall
     * @param requiredAmount Amount of liquidity required
     */
    function ensureLiquidity(uint256 requiredAmount) internal {
        uint256 availableLiquidity = getAvailableLiquidity();

        if (availableLiquidity < requiredAmount) {
            uint256 shortfall = requiredAmount - availableLiquidity;
            uint256 stakedAmount = getStakedAmount();

            if (stakedAmount >= shortfall) {
                // Withdraw exactly what we need
                stakingContract.withdraw(shortfall);
                emit StakingWithdrawn(shortfall, "Liquidity shortfall covered");
            } else if (stakedAmount > 0) {
                // Withdraw all staked if not enough
                stakingContract.withdraw(stakedAmount);
                emit StakingWithdrawn(stakedAmount, "Partial liquidity coverage");
            }
        }

        // Verify we have enough liquidity after attempting to cover shortfall
        availableLiquidity = getAvailableLiquidity();
        if (availableLiquidity < requiredAmount) revert InsufficientLiquidity(availableLiquidity, requiredAmount);
    }

    /**
     * @notice Rebalances the staking allocation based on target percentage
     * @dev Adjusts staked amount to maintain target STAKING_PERCENTAGE
     */
    function rebalanceStaking() internal {
        uint256 totalLiquidity = getAvailableLiquidity() + totalBorrows;
        uint256 currentStaked = getStakedAmount();
        uint256 targetStaked = (totalLiquidity * STAKING_PERCENTAGE) / 100;

        if (currentStaked > targetStaked + 1e18) {
            // We have too much staked, withdraw excess
            uint256 excessStaked = currentStaked - targetStaked;
            stakingContract.withdraw(excessStaked);
            emit DynamicStakingAdjusted(excessStaked, "Reduced staking");
        } else if (currentStaked < targetStaked && getAvailableLiquidity() > 0) {
            // We have too little staked, stake more (if we have liquidity)
            uint256 additionalStake = targetStaked - currentStaked;
            if (additionalStake > getAvailableLiquidity()) {
                additionalStake = getAvailableLiquidity();
            }
            stakingContract.stake(additionalStake);
            emit DynamicStakingAdjusted(additionalStake, "Increased staking");
        }
    }

    /**
     * @notice Calculates the borrow interest rate
     * @dev Rate is based on utilization rate with a base rate component
     * @param cash Available liquidity in the contract
     * @param borrows Total amount borrowed
     * @param reserves Amount held in reserves
     * @return Interest rate per block (scaled by 1e18)
     */
    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) public pure returns (uint256) {
        // If no borrows, return the base rate only (minimum rate)
        if (borrows == 0) return BASE_RATE_PER_BLOCK;

        uint256 totalAssets = cash + borrows;

        // If reserves exceed total assets (unlikely but handling edge case)
        if (totalAssets <= reserves) {
            totalAssets += 1; // Prevent division by zero
        } else {
            totalAssets = totalAssets - reserves;
        }

        // Calculate utilization rate: borrows / (cash + borrows - reserves)
        uint256 utilizationRate = (borrows * 1e18) / totalAssets;

        // Linear interest rate model: base rate + multiplier * utilization
        return BASE_RATE_PER_BLOCK + (utilizationRate * MULTIPLIER_PER_BLOCK / 1e18);
    }

    /**
     * @notice Claims staking rewards and updates exchange rate
     * @dev Distributes rewards to all cToken holders by increasing exchange rate
     */
    function claimAndUpdateRewards() public {
        uint256 pendingRewards = stakingContract.getPendingRewards(address(this));
        if (pendingRewards > 0) {
            // Claim rewards without withdrawing stake
            stakingContract.withdraw(0);
            totalStakingRewards += pendingRewards;

            // Calculate the increase in exchange rate based on total supply
            uint256 totalSupplyValue = totalSupply();
            if (totalSupplyValue > 0) {
                // Convert rewards to an exchange rate increase
                uint256 exchangeRateIncrease = (pendingRewards * 1e18) / totalSupplyValue;
                exchangeRateStored += exchangeRateIncrease;
            }

            emit RewardsAddedToReserves(pendingRewards);
        }
        lastRewardsClaim = block.timestamp;
    }

    /**
     * @notice Liquidates collateral from a user
     * @dev Burns all cTokens and transfers underlying to liquidator
     * @param account Address of user being liquidated
     * @param liquidator Address receiving the collateral
     * @param underlyingAmount Amount of underlying tokens to transfer
     * @return Amount of collateral liquidated
     */
    function liquidateCollateral(address account, address liquidator, uint256 underlyingAmount) external onlyOwner returns (uint256) {
        accrueInterest();

        // Calculate the actual cToken amount to burn based on exchange rate
        uint256 cTokenAmount = balanceOf(account);

        // Burn the cTokens
        _burn(account, cTokenAmount);

        // Ensure we have enough liquidity for the transfer
        ensureLiquidity(underlyingAmount);

        // Transfer the underlying tokens to the liquidator
        bool transferSuccess = underlyingToken.transfer(liquidator, underlyingAmount);
        if (!transferSuccess) revert TransferFailed(address(underlyingToken), liquidator, underlyingAmount);

        // Rebalance staking after liquidation
        rebalanceStaking();

        // Reset user's initial supply
        userInitialSupply[account] = 0;

        return underlyingAmount;
    }

    /**
     * @notice Accrues interest for all borrows
     * @dev Updates borrow index, exchange rate, and reserves based on elapsed blocks
     */
    function accrueInterest() public {
        uint256 currentBlockNumber = block.number;
        uint256 blockDelta = currentBlockNumber - accrualBlockNumber;

        if (blockDelta > 0) {
            uint256 cashPrior = underlyingToken.balanceOf(address(this));
            uint256 borrowsPrior = totalBorrows;
            uint256 totalSupplyPrior = totalSupply();

            // Calculate borrow interest rate and accumulated interest
            uint256 borrowRate = getBorrowRate(cashPrior, borrowsPrior, totalReservesStored);
            uint256 simpleInterestFactor = borrowRate * blockDelta;
            uint256 interestAccumulated = (simpleInterestFactor * borrowsPrior) / 1e18;

            // Update total borrows with accumulated interest
            if (totalBorrows > type(uint256).max - interestAccumulated) revert InterestAccumulationOverflow(totalBorrows, interestAccumulated);

            totalBorrows = borrowsPrior + interestAccumulated;

            // Calculate new reserves
            uint256 reserveDelta = (interestAccumulated * RESERVE_FACTOR) / 1e18;
            totalReservesStored += reserveDelta;

            // Need this to prevent underflow in calculations always keep a reserves on contract
            ensureLiquidity(totalReservesStored);

            // Update exchange rate only if there is supply and interest was accumulated
            if (totalSupplyPrior > 0 && interestAccumulated > 0) {
                // The exchange rate should only increase from interest earned
                uint256 interestForSuppliers = interestAccumulated - reserveDelta;
                if (interestForSuppliers > 0) {
                    // Calculate new exchange rate by adding the interest earned per cToken
                    uint256 exchangeRateIncrease = (interestForSuppliers * 1e18) / totalSupplyPrior;
                    exchangeRateStored += exchangeRateIncrease;
                }
            }

            // Update the borrow index with safe calculation
            uint256 newBorrowIndex = (borrowIndex * (1e18 + simpleInterestFactor)) / 1e18;
            if (newBorrowIndex < borrowIndex) {
                revert BorrowIndexOverflow(newBorrowIndex, borrowIndex);
            }
            borrowIndex = newBorrowIndex;

            accrualBlockNumber = currentBlockNumber;
        }
    }

    /**
     * @notice Calculates the annual percentage rate for borrowers
     * @return Borrow APR (scaled by 1e18)
     */
    function getBorrowAPR() public view returns (uint256) {
        uint256 cash = getAvailableLiquidity();
        uint256 borrowRate = getBorrowRate(cash, totalBorrows, totalReservesStored);

        // Calculate Borrow APR (annualized)
        uint256 borrowAPR = borrowRate * BLOCKS_PER_YEAR;

        return borrowAPR;
    }

    /**
     * @notice Calculates the annual percentage rate for suppliers
     * @dev Combines weighted APRs from both lending and staking
     * @return Supply APR (scaled by 1e18)
     */
    function getSupplyAPR() external view returns (uint256) {
        // Calculate Borrow APR (annualized)
        uint256 borrowAPR = getBorrowAPR();

        // Calculate net borrow APR (after reserve factor)
        uint256 netBorrowAPR = borrowAPR * (1e18 - RESERVE_FACTOR) / 1e18;

        // Get total assets - this is what we use to determine allocation percentages
        uint256 totalAssets = getAvailableLiquidity() + totalBorrows + getStakedAmount();

        // No division by zero
        if (totalAssets == 0) return 0;

        // Calculate the percentage of assets that are borrowed
        uint256 borrowUtilization = totalBorrows * 1e18 / totalAssets;

        // Calculate the percentage of assets that are staked
        uint256 stakingPercentage = getStakedAmount() * 1e18 / totalAssets;

        // Get Staking APY from staking contract
        uint256 stakingAPR = stakingContract.STAKING_APR();

        // Weight the APRs by their actual utilization
        uint256 weightedBorrowAPR = (netBorrowAPR * borrowUtilization) / 1e18;
        uint256 weightedStakingAPR = (stakingAPR * stakingPercentage) / 1e18;

        // Combine weighted APRs
        return weightedBorrowAPR + weightedStakingAPR;
    }

    /**
     * @notice Returns the current total reserves
     * @return Current reserves amount
     */
    function getTotalReserves() public view returns (uint256) {
        return totalReservesStored;
    }

    /**
     * @notice Allows owner to withdraw accumulated reserves
     * @param recipient Address to receive the reserves
     * @param amount Amount of reserves to withdraw
     */
    function withdrawReserves(address recipient, uint256 amount) external onlyOwner {
        require(amount <= totalReservesStored, "Insufficient reserves");
        if (amount > 0) totalReservesStored -= amount;
        ensureLiquidity(amount);
        bool transferSuccess = underlyingToken.transfer(recipient, amount);
        if (!transferSuccess) revert TransferFailed(address(underlyingToken), recipient, amount);
    }

    /**
     * @notice Returns user's initial supply amount
     * @param account User address to check
     * @return Initial supply amount
     */
    function getUserInitialSupply(address account) external view returns (uint256) {
        return userInitialSupply[account];
    }

    /**
     * @notice Calculates the underlying token value of a user's cTokens
     * @param account User address to check
     * @return Underlying token amount
     */
    function balanceOfUnderlying(address account) external view returns (uint256) {
        return balanceOf(account) * exchangeRateStored / 1e18;
    }

    /**
     * @notice Gets user's current borrow balance with accrued interest
     * @param account User address to check
     * @return Current borrow balance
     */
    function borrowBalanceCurrent(address account) external view returns (uint256) {
        return (accountBorrows[account] * borrowIndex + 1e18 / 2) / 1e18;
    }

    /**
     * @notice Returns the contract's available liquidity
     * @return Current liquidity (underlying tokens in contract)
     */
    function getAvailableLiquidity() public view returns (uint256) {
        return underlyingToken.balanceOf(address(this));
    }

    /**
     * @notice Gets the amount currently staked in the staking contract
     * @return Amount of tokens staked
     */
    function getStakedAmount() public view returns (uint256 stakedAmount) {
        (stakedAmount, , ) = stakingContract.getStakeInfo(address(this));
        return stakedAmount;
    }
}