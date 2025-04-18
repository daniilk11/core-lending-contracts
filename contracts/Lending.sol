// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

// Interface for CToken (Collateral Token)
interface ICToken {
    // View functions
    function underlyingToken() external view returns (address);
    function balanceOfUnderlying(address account) external view returns (uint256);
    function getUserInitialSupply(address account) external view returns (uint256);
    function borrowBalanceCurrent(address account) external view returns (uint256);
    function loanToValue() external view returns (uint256);

    // State-changing functions
    function mint(address user, uint256 underlyingAmount) external returns (uint256);
    function redeem(address user, uint256 cTokenAmount) external returns (uint256);
    function borrow(address user, uint256 borrowAmount) external;
    function repayBorrow(address user, uint256 repayAmount) external;
    function liquidateCollateral(
        address account,
        address liquidator,
        uint256 underlyingAmount
    ) external returns (uint256);
}

/// @title Advanced Lending Protocol
/// @notice Provides a comprehensive lending and borrowing platform with advanced features
/// @dev Implements core lending functionality with liquidation mechanisms
contract Lending is ReentrancyGuard, Ownable {
    // Constants
    uint256 public constant LIQUIDATION_REWARD = 5;
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    uint256 public constant MIN_HEALTH_FACTOR = 100e8;
    uint256 public constant MAX_POSITIONS_TO_CHECK = 10;
    uint256 public constant MAX_DEADLINE = 300; // 5 minutes
    uint256 public constant LIQUIDATION_COOLDOWN = 1 hours;

    // Configuration Variables
    uint256 public maxSlippage = 3;
    ISwapRouter public swapRouter;

    // Token Management
    mapping(address => address) public s_tokenToPriceFeed;
    mapping(address => address) public s_tokenToCToken;
    address[] public s_allowedTokens;

    // Borrower Tracking
    address[] private activeBorrowers;
    mapping(address => bool) private isActiveBorrower;
    mapping(address => uint256) public lastLiquidationAttempt;

    // Events
    event Deposit(address indexed account, address indexed token, uint256 indexed amount);
    event Borrow(address indexed account, address indexed token, uint256 indexed amount);
    event Withdraw(address indexed account, address indexed token, uint256 indexed amount);
    event Repay(address indexed account, address indexed token, uint256 indexed amount);
    event Liquidate(
        address indexed account,
        address indexed repayToken,
        address indexed rewardToken,
        address liquidator
    );
    event PlatformLiquidation(
        address indexed account,
        address indexed repayToken,
        uint256 healthFactor
    );

    // Custom Errors
    error TokenNotAllowed(address token);
    error NeedsMoreThanZero();
    error InsufficientHealthFactor();
    error AccountCannotBeLiquidated();
    error TokenAlreadySet(address token);
    error InvalidCtokenContract();
    error InvalidTokenContract();
    error TransferFailed(address token, address from, address to, uint256 amount);
    error InsufficientCollateralForLiquidation(uint256 available, uint256 required);
    error InsufficientRepayTokenBalance(uint256 available, uint256 required);

    /// @notice Constructor to initialize the lending contract
    /// @param _swapRouter Address of the Uniswap V3 swap router
    constructor(ISwapRouter _swapRouter) Ownable(msg.sender) {
        swapRouter = _swapRouter;
    }

    // Core Lending Functions
    /// @notice Deposit tokens to earn interest
    /// @param token Address of the token to deposit
    /// @param amount Amount of tokens to deposit
    function deposit(address token, uint256 amount)
    external
    nonReentrant
    moreThanZero(amount)
    isAllowedToken(token)
    {
        address cTokenAddress = s_tokenToCToken[token];
        ICToken cTokenContract = ICToken(cTokenAddress);

        bool success = IERC20(token).transferFrom(msg.sender, cTokenAddress, amount);
        if (!success) revert TransferFailed(token, msg.sender, cTokenAddress, amount);

        cTokenContract.mint(msg.sender, amount);
        emit Deposit(msg.sender, token, amount);
    }

    /// @notice Withdraw deposited tokens
    /// @param token Address of the token to withdraw
    /// @param cTokenAmount Amount of cTokens to redeem
    function withdraw(address token, uint256 cTokenAmount)
    external
    nonReentrant
    moreThanZero(cTokenAmount)
    isAllowedToken(token)
    {
        address cTokenAddress = s_tokenToCToken[token];
        ICToken cTokenContract = ICToken(cTokenAddress);

        uint256 underlyingAmount = cTokenContract.redeem(msg.sender, cTokenAmount);
        if (healthFactor(msg.sender) < MIN_HEALTH_FACTOR) revert InsufficientHealthFactor();

        emit Withdraw(msg.sender, token, underlyingAmount);
    }

    /// @notice Borrow tokens against collateral
    /// @param token Address of the token to borrow
    /// @param amount Amount of tokens to borrow
    function borrow(address token, uint256 amount)
    external
    nonReentrant
    isAllowedToken(token)
    moreThanZero(amount)
    {
        address cTokenAddress = s_tokenToCToken[token];
        ICToken cTokenContract = ICToken(cTokenAddress);

        cTokenContract.borrow(msg.sender, amount);

        if (healthFactor(msg.sender) < MIN_HEALTH_FACTOR) revert InsufficientHealthFactor();

        _registerBorrower(msg.sender);
        emit Borrow(msg.sender, token, amount);
    }

    /// @notice Repay borrowed tokens
    /// @param token Address of the token to repay
    /// @param amount Amount of tokens to repay
    function repay(address token, uint256 amount)
    external
    nonReentrant
    isAllowedToken(token)
    moreThanZero(amount)
    {
        address cTokenAddress = s_tokenToCToken[token];
        ICToken cTokenContract = ICToken(cTokenAddress);

        IERC20(token).transferFrom(msg.sender, address(cTokenContract), amount);
        cTokenContract.repayBorrow(msg.sender, amount);

        uint256 totalBorrowed = getAccountBorrowedValue(msg.sender);
        if (totalBorrowed == 0) {
            _removeBorrower(msg.sender);
        }

        emit Repay(msg.sender, token, amount);
    }

    // Liquidation Functions
    /// @notice Liquidate an undercollateralized account
    /// @param account Address of the account to liquidate
    /// @param repayToken Token used to repay the debt
    /// @param rewardToken Token received as reward for liquidation
    function liquidate(
        address account,
        address repayToken,
        address rewardToken
    )
    external
    nonReentrant
    isAllowedToken(repayToken)
    isAllowedToken(rewardToken)
    {
        if (healthFactor(account) >= MIN_HEALTH_FACTOR) revert AccountCannotBeLiquidated();

        address repayCTokenAddress = s_tokenToCToken[repayToken];
        address rewardCTokenAddress = s_tokenToCToken[rewardToken];

        ICToken repayCTokenContract = ICToken(repayCTokenAddress);
        ICToken rewardCTokenContract = ICToken(rewardCTokenAddress);

        uint256 amountToLiquidate = repayCTokenContract.borrowBalanceCurrent(account);

        uint256 amountToLiquidateInUSD = getUSDValue(repayToken, amountToLiquidate);
        uint256 rewardAmount = (amountToLiquidateInUSD * 1e18) / getUSDValue(rewardToken, 1e18);

        uint256 availableCollateral = rewardCTokenContract.balanceOfUnderlying(account);
        if (availableCollateral < rewardAmount) {
            revert InsufficientCollateralForLiquidation(availableCollateral, rewardAmount);
        }

        uint256 senderRepayTokenBalance = IERC20(repayToken).balanceOf(msg.sender);
        if (senderRepayTokenBalance < amountToLiquidate) {
            revert InsufficientRepayTokenBalance(senderRepayTokenBalance, amountToLiquidate);
        }

        IERC20(repayToken).transferFrom(msg.sender, address(repayCTokenContract), amountToLiquidate);
        repayCTokenContract.repayBorrow(account, amountToLiquidateInUSD);

        // Liquidate collateral and transfer reward directly to liquidator
        rewardCTokenContract.liquidateCollateral(account, msg.sender, rewardAmount);

        emit Liquidate(account, repayToken, rewardToken, msg.sender);
    }

    /// @notice Automated platform-wide liquidation check
    function checkAndLiquidatePositions() external nonReentrant {
        uint256 positionsChecked = 0;

        for (uint256 i = 0; i < activeBorrowers.length && positionsChecked < MAX_POSITIONS_TO_CHECK; i++) {
            address user = activeBorrowers[i];

            // Skip if user was recently checked
            if (block.timestamp - lastLiquidationAttempt[user] < LIQUIDATION_COOLDOWN) {
                continue;
            }

            // Update last check timestamp
            lastLiquidationAttempt[user] = block.timestamp;
            positionsChecked++;

            uint256 userHealthFactor = healthFactor(user);
            if (userHealthFactor < MIN_HEALTH_FACTOR) {
                (uint256 maxBorrowValue, address repayToken) = (0, address(0));
                (uint256 maxCollateralValue, address rewardToken) = (0, address(0));

                // Find highest borrow and collateral tokens
                for (uint256 j = 0; j < s_allowedTokens.length; j++) {
                    address token = s_allowedTokens[j];
                    address cTokenAddr = s_tokenToCToken[token];

                    if (cTokenAddr != address(0)) {
                        ICToken cToken = ICToken(cTokenAddr);

                        // Check borrows
                        uint256 borrowAmount = cToken.borrowBalanceCurrent(user);
                        uint256 borrowValue = getUSDValue(token, borrowAmount);
                        if (borrowValue > maxBorrowValue) {
                            maxBorrowValue = borrowValue;
                            repayToken = token;
                        }

                        // Check collateral
                        uint256 collateralAmount = cToken.balanceOfUnderlying(user);
                        uint256 collateralValue = getUSDValue(token, collateralAmount);
                        if (collateralValue > maxCollateralValue) {
                            maxCollateralValue = collateralValue;
                            rewardToken = token;
                        }
                    }
                }

                // Execute liquidation if positions found
                if (repayToken != address(0) && rewardToken != address(0)) {
                    _executePlatformLiquidation(user, repayToken);
                }
            }

            _removeBorrower(user);
        }
    }

    // Internal Helper Functions
    /// @notice Register a new active borrower
    /// @param user Address of the borrower
    function _registerBorrower(address user) internal {
        if (!isActiveBorrower[user]) {
            activeBorrowers.push(user);
            isActiveBorrower[user] = true;
        }
    }

    /// @notice Remove a borrower from active borrowers
    /// @param user Address of the borrower to remove
    function _removeBorrower(address user) internal {
        if (isActiveBorrower[user]) {
            isActiveBorrower[user] = false;
            // Find and remove user from activeBorrowers array
            for (uint i = 0; i < activeBorrowers.length; i++) {
                if (activeBorrowers[i] == user) {
                    activeBorrowers[i] = activeBorrowers[activeBorrowers.length - 1];
                    activeBorrowers.pop();
                    break;
                }
            }
        }
    }

    /// @notice Execute platform liquidation for an undercollateralized position
    /// @dev Liquidates collateral, swaps to repay token if needed, and repays user's debt
    /// @param user Address of the borrower to liquidate
    /// @param repayToken Address of the token to repay the debt with
    function _executePlatformLiquidation(address user, address repayToken) internal
    {
        address repayCTokenAddress = s_tokenToCToken[repayToken];
        ICToken repayCTokenContract = ICToken(repayCTokenAddress);

        // Iterate through all allowed tokens to liquidate collateral
        for (uint256 i = 0; i < s_allowedTokens.length; i++) {
            address collateralToken = s_allowedTokens[i];

            address collateralCTokenAddress = s_tokenToCToken[collateralToken];
            if (collateralCTokenAddress == address(0)) continue; // Skip if token not supported

            ICToken collateralCTokenContract = ICToken(collateralCTokenAddress);
            uint256 collateralAmount = collateralCTokenContract.balanceOfUnderlying(user);

            // If collateral is same as repay token, transfer directly without swap
            if (collateralToken == repayToken) {
                collateralCTokenContract.liquidateCollateral(user, address(collateralCTokenAddress), collateralAmount);
                continue;
            }

            if (collateralAmount > 0) {
                // Burn user's cTokens and transfer the collateral to main lending contract
                collateralCTokenContract.liquidateCollateral(user, address(this), collateralAmount);

                // Approve Uniswap to spend the collateral
                TransferHelper.safeApprove(collateralToken, address(swapRouter), collateralAmount);

                // Calculate minimum amount considering maximum slippage
                uint256 minAmountOut = (getUSDValue(collateralToken, collateralAmount) * (100 - maxSlippage)) / 100;

                // Setup the swap parameters for Uniswap
                ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
                    .ExactInputSingleParams({
                    tokenIn: collateralToken,
                    tokenOut: repayToken,
                    fee: 3000, // 0.3% fee tier
                    recipient: address(this),
                    deadline: block.timestamp + MAX_DEADLINE,
                    amountIn: collateralAmount,
                    amountOutMinimum: minAmountOut,
                    sqrtPriceLimitX96: 0
                });

                // Execute the swap on Uniswap
                uint256 amountReceived = swapRouter.exactInputSingle(params);

                // Transfer swapped tokens to repay cToken contract
                IERC20(repayToken).transfer(repayCTokenAddress, amountReceived);

                // Repay the borrowed amount for the user
                repayCTokenContract.repayBorrow(user, amountReceived);
            }
        }

        // Check if the position is fully closed
        uint256 remainingBorrows = getAccountBorrowedValue(user);
        if (remainingBorrows == 0) {
            _removeBorrower(user);
        }

        emit PlatformLiquidation(
            user,
            repayToken,
            healthFactor(user)
        );
    }

    /// @notice Get both borrowed and collateral values for a user
    /// @param user Address of the user to check
    /// @return borrowedValueInUSD Total borrowed value in USD
    /// @return collateralValueInUSD Total collateral value in USD (adjusted by LTV)
    function getAccountInformation(address user) public view returns (uint256 borrowedValueInUSD, uint256 collateralValueInUSD)
    {
        borrowedValueInUSD = getAccountBorrowedValue(user);
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    /// @notice Calculate the total collateral value for a user (adjusted by LTV)
    /// @param user Address of the user to check
    /// @return Total collateral value in USD (adjusted by each asset's loan-to-value ratio)
    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralValueInUSD = 0;
        for (uint256 index = 0; index < s_allowedTokens.length; index++) {
            address token = s_allowedTokens[index];
            address cTokenAddress = s_tokenToCToken[token];
            if (cTokenAddress != address(0)) {
                ICToken cTokenContract = ICToken(cTokenAddress);
                uint256 underlyingBalance = cTokenContract.balanceOfUnderlying(user);
                uint256 valueInUSD = getUSDValue(token, underlyingBalance);
                // Apply loan-to-value ratio to get usable collateral value
                totalCollateralValueInUSD += valueInUSD * cTokenContract.loanToValue() / 100;
            }
        }
        return totalCollateralValueInUSD;
    }

    /// @notice Calculate a user's total earned rewards
    /// @dev Compares current supply with initial supply to determine rewards
    /// @param user Address of the user to check
    /// @return Total value of rewards in USD
    function getUserRewards(address user) public view returns (uint256) {
        uint256 totalRewardValueInUSD = 0;
        for (uint256 index = 0; index < s_allowedTokens.length; index++) {
            address token = s_allowedTokens[index];
            address cTokenAddress = s_tokenToCToken[token];
            if (cTokenAddress != address(0)) {
                ICToken cTokenContract = ICToken(cTokenAddress);
                uint256 currentSupply = cTokenContract.balanceOfUnderlying(user);
                uint256 initialSupply = cTokenContract.getUserInitialSupply(user);
                // Calculate rewards as growth in supply (interest earned)
                uint256 supplyReward = currentSupply > initialSupply ? currentSupply - initialSupply : 0;
                totalRewardValueInUSD += getUSDValue(token, supplyReward);
            }
        }
        return totalRewardValueInUSD;
    }

    /// @notice Calculate the total borrowed value for a user across all tokens
    /// @param user Address of the user to check
    /// @return Total borrowed value in USD
    function getAccountBorrowedValue(address user) public view returns (uint256) {
        uint256 totalBorrowsValueInUSD = 0;
        for (uint256 index = 0; index < s_allowedTokens.length; index++) {
            address token = s_allowedTokens[index];
            address cTokenAddress = s_tokenToCToken[token];
            if (cTokenAddress != address(0)) {
                ICToken cTokenContract = ICToken(cTokenAddress);
                uint256 borrowedAmount = cTokenContract.borrowBalanceCurrent(user);
                uint256 valueInUSD = getUSDValue(token, borrowedAmount);
                totalBorrowsValueInUSD += valueInUSD;
            }
        }
        return totalBorrowsValueInUSD;
    }

    /// @notice Convert token amount to USD value using price feed
    /// @dev Normalizes decimals between token and price feed
    /// @param token Address of the token to value
    /// @param amount Amount of tokens to convert to USD
    /// @return USD value with 18 decimal places
    function getUSDValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (, int256 price, , ,) = priceFeed.latestRoundData();
        // Get token decimals
        uint8 tokenDecimals = IERC20Metadata(token).decimals();

        // Scale all numbers to 18 decimals (oracle has 8 decimals)
        return (uint256(price) * amount * 10**(18 - tokenDecimals)) / 1e8;
    }

    /// @notice Calculate health factor for an account
    /// @dev Health factor = collateral value / borrowed value * 1e10
    /// @param account Address of the account to check
    /// @return Health factor with 10 decimal places (1e10 = 100% healthy)
    function healthFactor(address account) public view returns (uint256) {
        (uint256 borrowedValueInUSD, uint256 collateralValueInUSD) = getAccountInformation(account);
        if (borrowedValueInUSD == 0) return type(uint256).max; // If no debt, health factor is maximum
        return (collateralValueInUSD * 1e10) / borrowedValueInUSD;
    }

    /// @notice Modifier to check if a token is allowed in the protocol
    /// @param token Address of the token to check
    modifier isAllowedToken(address token) {
        if (s_tokenToPriceFeed[token] == address(0)) revert TokenNotAllowed(token);
        _;
    }

    /// @notice Modifier to verify amount is greater than zero
    /// @param amount Value to check
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert NeedsMoreThanZero();
        _;
    }

    /// @notice Add a new token to the allowed tokens list
    /// @dev Links token with its cToken contract and price feed
    /// @param token Address of the underlying token
    /// @param cToken Address of the corresponding cToken contract
    /// @param priceFeed Address of the Chainlink price feed for the token
    function setAllowedToken(
        address token,
        address cToken,
        address priceFeed
    ) external onlyOwner {
        if (s_tokenToCToken[token] != address(0)) revert TokenAlreadySet(token);
        if (cToken == address(0)) revert InvalidCtokenContract();
        if (token == address(0)) revert InvalidTokenContract();

        s_allowedTokens.push(token);
        s_tokenToPriceFeed[token] = priceFeed;
        s_tokenToCToken[token] = cToken;
    }

    /// @notice Get list of all allowed tokens in the protocol
    /// @return Array of token addresses
    function getAllowedTokens() external view returns (address[] memory) {
        return s_allowedTokens;
    }

    /// @notice Get the cToken address for a given underlying token
    /// @param token Address of the underlying token
    /// @return Address of the corresponding cToken contract
    function getCTokenAddress(address token) external view returns (address) {
        return s_tokenToCToken[token];
    }
}