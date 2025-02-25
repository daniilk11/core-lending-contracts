// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

    error TransferFailed();
    error TokenNotAllowed(address token);
    error NeedsMoreThanZero();

contract CToken is ERC20 {
    IERC20 public immutable underlyingToken;
    uint256 public totalBorrows;
    uint256 public reserveFactor;
    uint256 public exchangeRateStored;
    uint256 public borrowIndex;
    uint256 public accrualBlockNumber;
    uint256 public loanToValue = 0.75;
    uint256 public constant borrowRateMaxMantissa = 0.0005e16;
    uint256 public constant reserveFactorMaxMantissa = 1e18;

    mapping(address => uint256) public accountBorrows;

    constructor(IERC20 _underlyingToken, string memory name, string memory symbol)
    ERC20(name, symbol)
    {
        underlyingToken = _underlyingToken;
        exchangeRateStored = 1e18; // 1:1 initial exchange rate
        borrowIndex = 1e18; // initial borrow index
        accrualBlockNumber = block.number;
    }

    function mint(address user, uint256 underlyingAmount) external returns (uint256) {
        accrueInterest();
        // require(underlyingToken.transferFrom(msg.sender, address(this), underlyingAmount), "Transfer failed");

        uint256 cTokenAmount;
        uint256 currentSupply = totalSupply();

        if (currentSupply > 0) {
            // Standard minting: calculate based on exchange rate
            cTokenAmount = underlyingAmount * 1e18 / exchangeRateStored;
        } else {
            // Initial minting: 1:1 exchange rate
            cTokenAmount = underlyingAmount;
        }

        _mint(user, cTokenAmount);
        return cTokenAmount;
    }

    function redeem(address user, uint256 cTokenAmount) external returns (uint256) {
        accrueInterest();
        uint256 underlyingAmount = cTokenAmount * exchangeRateStored / 1e18;
        _burn(user, cTokenAmount);
        require(underlyingToken.transfer(user, underlyingAmount), "Transfer failed");
        return underlyingAmount;
    }

    function borrow(address user, uint256 borrowAmount) external {
        accrueInterest();
        require(underlyingToken.balanceOf(address(this)) >= borrowAmount, "Insufficient liquidity");
        accountBorrows[user] += borrowAmount * 1e18 / borrowIndex;
        totalBorrows += borrowAmount;
        require(underlyingToken.transfer(user, borrowAmount), "Transfer failed");
    }

    function repayBorrow(address user, uint256 repayAmount) external {
        accrueInterest();
        require(underlyingToken.transferFrom(user, address(this), repayAmount), "Transfer failed");
        uint256 accountBorrowsNew = accountBorrows[user] * borrowIndex / 1e18;
        if (repayAmount > accountBorrowsNew) {
            accountBorrows[user] = 0;
            totalBorrows -= accountBorrowsNew;
        } else {
            accountBorrows[user] = accountBorrowsNew - repayAmount;
            totalBorrows -= repayAmount;
        }
    }

    function accrueInterest() public {
        uint256 currentBlockNumber = block.number;
        uint256 blockDelta = currentBlockNumber - accrualBlockNumber;
        if (blockDelta > 0) {
            uint256 cashPrior = underlyingToken.balanceOf(address(this));
            uint256 borrowsPrior = totalBorrows;
            uint256 reservesPrior = totalReserves();

            uint256 borrowRate = getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
            uint256 interestAccumulated = borrowsPrior > 0 ? (borrowRate * blockDelta * borrowsPrior) / 1e18 : 0;

            totalBorrows += interestAccumulated;

            // Avoid division by zero by checking totalSupply
            uint256 totalSupplyValue = totalSupply();
            if (totalSupplyValue > 0) {
                uint256 totalReservesNew = reservesPrior + (interestAccumulated * reserveFactor / 1e18);
                exchangeRateStored = (cashPrior + borrowsPrior - totalReservesNew) * 1e18 / totalSupplyValue;
            } else {
                // Default initial exchange rate if no supply exists yet
                exchangeRateStored = 1e18;
            }

            borrowIndex = borrowIndex * (1e18 + (borrowRate * blockDelta)) / 1e18;
            accrualBlockNumber = currentBlockNumber;
        }
    }

    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) public pure returns (uint256) {
        uint256 utilizationRate = borrows > 0 ? borrows * 1e18 / (cash + borrows - reserves) : 0;
        return utilizationRate * borrowRateMaxMantissa / 1e18;
    }

    function totalReserves() public view returns (uint256) {
        uint256 totalSupplyValue = totalSupply();
        if (totalSupplyValue == 0) return 0;
        return underlyingToken.balanceOf(address(this)) + totalBorrows - (totalSupplyValue * exchangeRateStored / 1e18);
    }

    function balanceOfUnderlying(address account) external view returns (uint256) {
        return balanceOf(account) * exchangeRateStored / 1e18;
    }

    function borrowBalanceCurrent(address account) external view returns (uint256) {
        return accountBorrows[account] * borrowIndex / 1e18;
    }
}

contract Lending is ReentrancyGuard, Ownable {
    mapping(address => address) public s_tokenToPriceFeed;
    mapping(address => address) public s_tokenToCToken;
    address[] public s_allowedTokens;

    uint256 public constant LIQUIDATION_REWARD = 5;
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    uint256 public constant MIN_HEALTH_FACTOR = 1e8;

    ISwapRouter public immutable swapRouter;

    event AllowedTokenSet(address indexed token, address indexed priceFeed, address indexed cToken);
    event Deposit(address indexed account, address indexed token, uint256 indexed amount);
    event Borrow(address indexed account, address indexed token, uint256 indexed amount);
    event Withdraw(address indexed account, address indexed token, uint256 indexed amount);
    event Repay(address indexed account, address indexed token, uint256 indexed amount);
    event Liquidate(
        address indexed account,
        address indexed repayToken,
        address indexed rewardToken,
        uint256 halfDebtInEth,
        address liquidator
    );

    constructor(ISwapRouter _swapRouter) Ownable(msg.sender) {
        swapRouter = _swapRouter;
    }

    function deposit(address token, uint256 amount) external nonReentrant isAllowedToken(token) moreThanZero(amount) {
        address cTokenAddress = s_tokenToCToken[token];
        require(cTokenAddress != address(0), "CToken not found");
        CToken cTokenContract = CToken(cTokenAddress);

        require(IERC20(token).transferFrom(msg.sender, cTokenAddress, amount), "Transfer failed");

        cTokenContract.mint(msg.sender, amount);
        IERC20(token).approve(cTokenAddress, amount);

        emit Deposit(msg.sender, token, amount);
    }

    function withdraw(address token, uint256 cTokenAmount) external nonReentrant moreThanZero(cTokenAmount) {
        address cTokenAddress = s_tokenToCToken[token];
        require(cTokenAddress != address(0), "CToken not found");
        CToken cTokenContract = CToken(cTokenAddress);

        uint256 underlyingAmount = cTokenContract.redeem(msg.sender, cTokenAmount);
        require(IERC20(token).transfer(msg.sender, underlyingAmount), "Transfer failed");

        emit Withdraw(msg.sender, token, underlyingAmount);
        require(healthFactor(msg.sender) >= MIN_HEALTH_FACTOR, "Platform will go insolvent!");
    }

    function borrow(address token, uint256 amount)
    external
    nonReentrant
    isAllowedToken(token)
    moreThanZero(amount)
    {
        address cTokenAddress = s_tokenToCToken[token];
        require(cTokenAddress != address(0), "CToken not found");
        CToken cTokenContract = CToken(cTokenAddress);

        cTokenContract.borrow(msg.sender, amount);

        emit Borrow(msg.sender, token, amount);

        require(healthFactor(msg.sender) >= MIN_HEALTH_FACTOR, "Borrow would put account below minimum health factor");
    }

    function repay(address token, uint256 amount)
    external
    nonReentrant
    isAllowedToken(token)
    moreThanZero(amount)
    {
        address cTokenAddress = s_tokenToCToken[token];
        require(cTokenAddress != address(0), "CToken not found");
        CToken cTokenContract = CToken(cTokenAddress);

        IERC20(token).transferFrom(msg.sender, address(cTokenContract), amount);
        cTokenContract.repayBorrow(msg.sender, amount);

        emit Repay(msg.sender, token, amount);
    }

    function liquidate(
        address account,
        address repayToken,
        address rewardToken
    ) external nonReentrant {
        require(healthFactor(account) < MIN_HEALTH_FACTOR, "Account can't be liquidated");

        address repayCTokenAddress = s_tokenToCToken[repayToken];
        address rewardCTokenAddress = s_tokenToCToken[rewardToken];
        require(repayCTokenAddress != address(0) && rewardCTokenAddress != address(0), "CTokens not found");

        CToken repayCTokenContract = CToken(repayCTokenAddress);
        CToken rewardCTokenContract = CToken(rewardCTokenAddress);

        uint256 halfDebt = repayCTokenContract.borrowBalanceCurrent(account) / 2;
        uint256 halfDebtInUSD = getUSDValue(repayToken, halfDebt);
        require(halfDebtInUSD > 0, "Debt too small to liquidate");

        uint256 rewardAmountInUSD = (halfDebtInUSD * (100 + LIQUIDATION_REWARD)) / 100;
        uint256 rewardAmount = (rewardAmountInUSD * 1e18) / getUSDValue(rewardToken, 1e18);

        require(rewardCTokenContract.balanceOfUnderlying(account) >= rewardAmount, "Not enough collateral to liquidate");

        IERC20(repayToken).transferFrom(msg.sender, address(repayCTokenContract), halfDebt);
        repayCTokenContract.repayBorrow(msg.sender, halfDebt);

        rewardCTokenContract.transferFrom(account, msg.sender, rewardAmount);

        emit Liquidate(account, repayToken, rewardToken, halfDebtInUSD, msg.sender);
    }

    function getAccountInformation(address user) public view
    returns (uint256 borrowedValueInUSD, uint256 collateralValueInUSD)
    {
        borrowedValueInUSD = getAccountBorrowedValue(user);
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralValueInUSD = 0;
        for (uint256 index = 0; index < s_allowedTokens.length; index++) {
            address token = s_allowedTokens[index];
            address cTokenAddress = s_tokenToCToken[token];
            if (cTokenAddress != address(0)) {
                CToken cTokenContract = CToken(cTokenAddress);
                uint256 underlyingBalance = cTokenContract.balanceOfUnderlying(user);
                uint256 valueInUSD = getUSDValue(token, underlyingBalance);
                totalCollateralValueInUSD += valueInUSD * cTokenContract.loanToValue;
            }
        }
        return totalCollateralValueInUSD;
    }

    function getAccountBorrowedValue(address user) public view returns (uint256) {
        uint256 totalBorrowsValueInUSD = 0;
        for (uint256 index = 0; index < s_allowedTokens.length; index++) {
            address token = s_allowedTokens[index];
            address cTokenAddress = s_tokenToCToken[token];
            if (cTokenAddress != address(0)) {
                CToken cTokenContract = CToken(cTokenAddress);
                uint256 borrowedAmount = cTokenContract.borrowBalanceCurrent(user);
                uint256 valueInUSD = getUSDValue(token, borrowedAmount);
                totalBorrowsValueInUSD += valueInUSD;
            }
        }
        return totalBorrowsValueInUSD;
    }

    function getUSDValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        // scale all numbers to 18 decimals oracle have 8 decimals
        return (uint256(price) * amount) / 1e8;
    }

    function healthFactor(address account) public view returns (uint256) {
        (uint256 borrowedValueInUSD, uint256 collateralValueInUSD) = getAccountInformation(account);
        if (borrowedValueInUSD == 0) return 1;
        return collateralValueInUSD / borrowedValueInUSD * 1e8 ;
    } 

    modifier isAllowedToken(address token) {
        if (s_tokenToPriceFeed[token] == address(0)) revert TokenNotAllowed(token);
        _;
    }

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert NeedsMoreThanZero();
        }
        _;
    }

    function setAllowedToken(address token, address priceFeed, string memory cTokenName, string memory cTokenSymbol) external onlyOwner {
        require(s_tokenToCToken[token] == address(0), "Token already set");

        s_allowedTokens.push(token);
        s_tokenToPriceFeed[token] = priceFeed;

        CToken newCToken = new CToken(IERC20(token), cTokenName, cTokenSymbol);
        s_tokenToCToken[token] = address(newCToken);

        emit AllowedTokenSet(token, priceFeed, address(newCToken));
    }
}