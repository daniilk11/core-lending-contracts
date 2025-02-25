// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockDexRouter is ISwapRouter {
    mapping(address => mapping(address => uint256)) public quotes;

    function setQuote(
        address fromToken,
        address toToken,
        uint256 amount
    ) external {
        quotes[fromToken][toToken] = amount;
    }

    function getAmountOut(
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    ) external view returns (uint256 amountOut) {
        return quotes[tokenIn][tokenOut];
    }

    function getQuote(
        address fromToken,
        address toToken,
        uint256 amountIn
    ) external view returns (uint256) {
        return quotes[fromToken][toToken];
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = quotes[path[0]][path[1]];
        require(amountOut >= amountOutMin, "Insufficient output amount");
        IERC20(path[1]).transfer(to, amountOut);
        return new uint256[](2);
    }
}