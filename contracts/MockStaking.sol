// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MockStaking is Ownable, ReentrancyGuard {
    IERC20 public immutable stakingToken;
    
    // Constants for APY calculation
    uint256 public constant STAKING_APR = 0.1e18; // 10% APY
    uint256 public constant SECONDS_PER_YEAR = 31536000;
    
    // Staking info
    struct StakeInfo {
        uint256 amount;
        uint256 timestamp;
        uint256 rewardDebt;
    }
    
    mapping(address => StakeInfo) public stakes;
    uint256 public totalStaked;
    uint256 public lastUpdateTime;
    uint256 public accumulatedRewardsPerShare;
    
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 rewards);
    event RewardsHarvested(address indexed user, uint256 rewards);
    
    constructor(IERC20 _stakingToken) Ownable(msg.sender) {
        stakingToken = _stakingToken;
        lastUpdateTime = block.timestamp;
    }
    
    function updateRewards() public {
        if (totalStaked == 0) {
            lastUpdateTime = block.timestamp;
            return;
        }
        
        uint256 timePassed = block.timestamp - lastUpdateTime;
        if (timePassed > 0) {
            // Calculate rewards based on APY
            uint256 rewards = (totalStaked * STAKING_APR * timePassed) / (SECONDS_PER_YEAR * 1e18);
            accumulatedRewardsPerShare += (rewards * 1e18) / totalStaked;
            lastUpdateTime = block.timestamp;
        }
    }
    
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Cannot stake 0");
        updateRewards();
        
        // Transfer tokens to contract
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        // Update stake info
        StakeInfo storage userStake = stakes[msg.sender];
        
        // Calculate pending rewards before updating stake
        uint256 pending = (userStake.amount * accumulatedRewardsPerShare) / 1e18 - userStake.rewardDebt;
        
        userStake.amount += amount;
        totalStaked += amount;
        userStake.timestamp = block.timestamp;
        userStake.rewardDebt = (userStake.amount * accumulatedRewardsPerShare) / 1e18;
        
        // Transfer any pending rewards
        if (pending > 0) {
            require(stakingToken.transfer(msg.sender, pending), "Reward transfer failed");
            emit RewardsHarvested(msg.sender, pending);
        }
        
        emit Staked(msg.sender, amount);
    }
    
    function withdraw(uint256 amount) external nonReentrant {
        StakeInfo storage userStake = stakes[msg.sender];
        require( amount <= userStake.amount, "Invalid withdraw amount");
        
        updateRewards();
        
        // Calculate rewards
        uint256 pending = (userStake.amount * accumulatedRewardsPerShare) / 1e18 - userStake.rewardDebt;
        
        // Update state
        userStake.amount -= amount;
        totalStaked -= amount;
        userStake.rewardDebt = (userStake.amount * accumulatedRewardsPerShare) / 1e18;
        
        // Transfer tokens and rewards
        require(stakingToken.transfer(msg.sender, amount + pending), "Transfer failed");
        
        emit Withdrawn(msg.sender, amount, pending);
    }
    
    function getPendingRewards(address user) external view returns (uint256) {
        StakeInfo storage userStake = stakes[user];
        if (userStake.amount == 0) {
            return 0;
        }
        
        uint256 _accumulatedRewardsPerShare = accumulatedRewardsPerShare;
        if (totalStaked > 0) {
            uint256 timePassed = block.timestamp - lastUpdateTime;
            uint256 rewards = (totalStaked * STAKING_APR * timePassed) / (SECONDS_PER_YEAR * 1e18);
            _accumulatedRewardsPerShare += (rewards * 1e18) / totalStaked;
        }
        
        return (userStake.amount * _accumulatedRewardsPerShare) / 1e18 - userStake.rewardDebt;
    }
    
    function getStakeInfo(address user) external view returns (
        uint256 stakedAmount,
        uint256 stakingTime,
        uint256 pendingRewards
    ) {
        StakeInfo storage userStake = stakes[user];
        return (
            userStake.amount,
            userStake.timestamp,
            this.getPendingRewards(user)
        );
    }
}