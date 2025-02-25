// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

contract MockSwapRouter is ISwapRouter {
    // Fixed rates (scaled by 1e18)
    uint256 private constant WETH_PRICE = 2000e18; // 1 ETH = 2000 USD
    
    mapping(address => mapping(address => uint256)) public exchangeRates;
    
    // Events to track swaps
    event SwapExecuted(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event LiquidityAdded(
        address token,
        uint256 amount
    );

    constructor(address weth, address usdc) {
        // Set exchange rates both ways
        exchangeRates[weth][usdc] = WETH_PRICE; // 1 ETH = 2000 USDC
        exchangeRates[usdc][weth] = 1e18 / 2000; // 2000 USDC = 1 ETH
    }

    // Function to add liquidity to the router
    function addLiquidity(address token, uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        TransferHelper.safeTransferFrom(token, msg.sender, address(this), amount);
        emit LiquidityAdded(token, amount);
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        // Calculate output amount based on fixed rate
        amountOut = calculateOutputAmount(
            params.tokenIn,
            params.tokenOut,
            params.amountIn
        );

        // Check if the router has enough output tokens
        require(
            IERC20(params.tokenOut).balanceOf(address(this)) >= amountOut,
            "Insufficient liquidity"
        );

        // Transfer input tokens from sender to this contract
        TransferHelper.safeTransferFrom(
            params.tokenIn,
            msg.sender,
            address(this),
            params.amountIn
        );

        // Transfer output tokens to recipient
        TransferHelper.safeTransfer(params.tokenOut, params.recipient, amountOut);

        emit SwapExecuted(
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            amountOut
        );

        return amountOut;
    }

    function calculateOutputAmount(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) public view returns (uint256) {
        uint256 rate = exchangeRates[tokenIn][tokenOut];
        return (amountIn * rate) / 1e18;
    }

    // Function to check router's token balance
    function getRouterBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // Required interface functions with minimal implementation
    function exactInput(ExactInputParams calldata params)
        external
        payable
        returns (uint256)
    {
        return 0;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        returns (uint256)
    {
        return 0;
    }

    function exactOutput(ExactOutputParams calldata params)
        external
        payable
        returns (uint256)
    {
        return 0;
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // Empty implementation
    }
}