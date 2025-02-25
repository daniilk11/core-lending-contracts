// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

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

contract CToken is ERC20, Ownable {
    // Immutable variables
    IERC20 public immutable underlyingToken;
    IStaking public stakingContract;

    // State variables
    uint256 public totalBorrows;
    uint256 public exchangeRateStored;
    uint256 public borrowIndex;
    uint256 public accrualBlockNumber;
    uint256 public loanToValue;
    uint256 public totalStakingRewards;
    uint256 public lastRewardsClaim;

    // Constants
    uint256 public constant STAKING_PERCENTAGE = 50; // 50% of deposits go to staking
    uint256 public constant RESERVE_FACTOR = 0.1e18; // 10% for reserve
    uint256 public constant BASE_RATE_PER_BLOCK = 826282390; //  1% base APY
    uint256 public constant MULTIPLIER_PER_BLOCK = 8262823902; // 10% at 100% utilization
    uint256 public constant BLOCKS_PER_YEAR = 12102400;

    // Mappings
    mapping(address => uint256) public accountBorrows;

    // Events
    event StakingWithdrawn(uint256 amount, string reason);
    event RewardsAddedToReserves(uint256 amount);
    event DynamicStakingAdjusted(uint256 amount, string reason);

    // Errors
    error TransferFailed(address token, address to, uint256 amount);
    error InterestAccumulationOverflow(uint256 currentBorrows, uint256 interestAccumulated);
    error InsufficientLiquidity(uint256 available, uint256 required);
    error BorrowIndexOverflow(uint256 newBorrowIndex, uint256 currentBorrowIndex);

    // Constructor
    constructor(
        IERC20 _underlyingToken,
        string memory name,
        string memory symbol,
        address _stakingContract,
        address owner
    ) ERC20(name, symbol) Ownable(owner) {
        underlyingToken = _underlyingToken;
        stakingContract = IStaking(_stakingContract);
        exchangeRateStored = 1e18;
        borrowIndex = 1e18;
        loanToValue = 75;
        accrualBlockNumber = block.number;
        lastRewardsClaim = block.timestamp;

        // Approve staking contract to spend tokens
        underlyingToken.approve(_stakingContract, type(uint256).max);
    }

    // Public Functions
    function mint(address user, uint256 underlyingAmount) external onlyOwner returns (uint256) {
        accrueInterest();

        // Stake tokens
        uint256 stakingAmount = (underlyingAmount * STAKING_PERCENTAGE) / 100;
        stakingContract.stake(stakingAmount);
        
        uint256 currentSupply = totalSupply();
        uint256 cTokenAmount;

        if (currentSupply > 0) {
            cTokenAmount = underlyingAmount * 1e18 / exchangeRateStored;
        } else {
            cTokenAmount = underlyingAmount;
        }

        _mint(user, cTokenAmount);
        return cTokenAmount;
    }

    
    function borrow(address user, uint256 borrowAmount) external onlyOwner {
        accrueInterest();
        
        // Ensure we have enough liquidity for the borrow
        ensureLiquidity(borrowAmount);
        
        accountBorrows[user] += ((borrowAmount * 1e18) + borrowIndex / 2) / borrowIndex;
        totalBorrows += borrowAmount;
        
        bool transferSuccess = underlyingToken.transfer(user, borrowAmount);
        if (!transferSuccess) revert TransferFailed(address(underlyingToken), user, borrowAmount);
    }

    function redeem(address user, uint256 cTokenAmount) external onlyOwner returns (uint256) {
        accrueInterest();
        claimAndUpdateRewards();
        
        uint256 underlyingAmount = cTokenAmount * exchangeRateStored / 1e18;
        
        // Ensure we have enough liquidity for redemption
        ensureLiquidity(underlyingAmount);
        
        _burn(user, cTokenAmount);
        
        bool transferSuccess = underlyingToken.transfer(user, underlyingAmount);
        if (!transferSuccess) revert TransferFailed(address(underlyingToken), user, underlyingAmount);
        
        return underlyingAmount;
    }

    function repayBorrow(address user, uint256 repayAmount) external onlyOwner {
        accrueInterest();

        // Calculate the current borrow balance in scaled terms
        uint256 accountBorrowsNew = accountBorrows[user] * borrowIndex / 1e18;
    
        if (repayAmount > accountBorrowsNew) {
            accountBorrows[user] = 0;
            totalBorrows -= accountBorrowsNew;
        } else {
            accountBorrows[user] = accountBorrowsNew - repayAmount;
            totalBorrows -= repayAmount;
        }
    }

    function ensureLiquidity(uint256 requiredAmount) internal {
        uint256 availableLiquidity = getAvailableLiquidity();
        
        if (availableLiquidity < requiredAmount) {
            uint256 shortfall = requiredAmount - availableLiquidity;
            uint256 stakedAmount = getStakedAmount();
            
            if (stakedAmount >= shortfall) {
                stakingContract.withdraw(shortfall);
                emit StakingWithdrawn(shortfall, "Liquidity shortfall covered");
            } else if (stakedAmount > 0) {
                stakingContract.withdraw(stakedAmount);
                emit StakingWithdrawn(stakedAmount, "Partial liquidity coverage");
            }
        }

        availableLiquidity = getAvailableLiquidity();
        if (availableLiquidity < requiredAmount) revert InsufficientLiquidity(availableLiquidity, requiredAmount);
    }
    

    function rebalanceStaking() internal {
        uint256 totalLiquidity = getAvailableLiquidity() + totalBorrows;
        uint256 currentStaked = getStakedAmount();
        uint256 targetStaked = (totalLiquidity * STAKING_PERCENTAGE) / 100;
        
        if (currentStaked > targetStaked + 1e18) { 
            uint256 excessStaked = currentStaked - targetStaked;
            stakingContract.withdraw(excessStaked);
            emit DynamicStakingAdjusted(excessStaked, "Reduced staking");
        } else if (currentStaked < targetStaked && getAvailableLiquidity() > 0) {
            uint256 additionalStake = targetStaked - currentStaked;
            if (additionalStake > getAvailableLiquidity()) {
                additionalStake = getAvailableLiquidity();
            }
            stakingContract.stake(additionalStake);
            emit DynamicStakingAdjusted(additionalStake, "Increased staking");
        }
    }

    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) public pure returns (uint256) {
        uint256 totalAssets = cash + borrows - reserves;
        if (totalAssets == 0) return 0;

        uint256 utilizationRate = (borrows * 1e18) / totalAssets;
        
        return BASE_RATE_PER_BLOCK + (utilizationRate * MULTIPLIER_PER_BLOCK / 1e18);
    }

    function claimAndUpdateRewards() public {
        uint256 pendingRewards = stakingContract.getPendingRewards(address(this));
        if (pendingRewards > 0) {
            stakingContract.withdraw(0); // Claim rewards without withdrawing stake
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
        
        return underlyingAmount;
    }

    function accrueInterest() public {
        uint256 currentBlockNumber = block.number;
        uint256 blockDelta = currentBlockNumber - accrualBlockNumber;
        
        if (blockDelta > 0) {
            uint256 cashPrior = underlyingToken.balanceOf(address(this));
            uint256 borrowsPrior = totalBorrows;
            uint256 reservesPrior = totalReserves();
            uint256 totalSupplyPrior = totalSupply();

            // Calculate borrow interest rate and accumulated interest
            uint256 borrowRate = getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
            uint256 simpleInterestFactor = borrowRate * blockDelta;
            uint256 interestAccumulated = (simpleInterestFactor * borrowsPrior) / 1e18;

            // Update total borrows with accumulated interest
            if (totalBorrows > type(uint256).max - interestAccumulated) revert InterestAccumulationOverflow(totalBorrows, interestAccumulated);
    
            totalBorrows = borrowsPrior + interestAccumulated;

            // Calculate new reserves
            uint256 reserveDelta = (interestAccumulated * RESERVE_FACTOR) / 1e18;
            
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

    // approximately 
    function getSupplyAPR() external view returns (uint256) {
        uint256 cash = underlyingToken.balanceOf(address(this));
        uint256 borrowRate = getBorrowRate(cash, totalBorrows, totalReserves());
        
        // Calculate Borrow APR (annualized)
        uint256 borrowAPR = borrowRate * BLOCKS_PER_YEAR;
        
        // Calculate net borrow APR (after reserve factor)
        uint256 netBorrowAPR = borrowAPR * (1e18 - RESERVE_FACTOR) / 1e18;
        
        // Get Staking APY from staking contract constant
        uint256 stakingAPY = stakingContract.STAKING_APR();
        
        // Combine net borrow APR with staking APY
        return netBorrowAPR + stakingAPY;
    }

    function totalReserves() public view returns (uint256) {
        uint256 totalSupplyValue = totalSupply();
        if (totalSupplyValue == 0) return 0;
        
        // Calculate total assets first
        uint256 totalAssets = underlyingToken.balanceOf(address(this)) + totalBorrows;
        
        // Calculate total supply value in underlying terms
        uint256 totalSupplyInUnderlying = (totalSupplyValue * exchangeRateStored) / 1e18;
        
        // If total assets is less than total supply value, return 0 instead of underflow
        if (totalAssets <= totalSupplyInUnderlying) {
            return 0;
        }
        
        return totalAssets - totalSupplyInUnderlying;
    }

    function withdrawReserves(address recipient, uint256 amount) external onlyOwner {
        uint256 currentReserves = totalReserves();
        require(amount <= currentReserves, "Insufficient reserves");
        bool transferSuccess = underlyingToken.transfer(recipient, amount);
        if (!transferSuccess) revert TransferFailed(address(underlyingToken), recipient, amount);
    }

    function balanceOfUnderlying(address account) external view returns (uint256) {
        return balanceOf(account) * exchangeRateStored / 1e18;
    }

    function borrowBalanceCurrent(address account) external view returns (uint256) {
        return (accountBorrows[account] * borrowIndex + 1e18 / 2) / 1e18;
    }
        
    function getAvailableLiquidity() public view returns (uint256) {
        return underlyingToken.balanceOf(address(this));
    }

    function getStakedAmount() public view returns (uint256 stakedAmount) {
        (stakedAmount, , ) = stakingContract.getStakeInfo(address(this));
        return stakedAmount;
    }
}
