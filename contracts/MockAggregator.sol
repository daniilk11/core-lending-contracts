// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockV3Aggregator
 * @notice A mock implementation of Chainlink's V3 Aggregator for testing purposes
 * @dev Simulates price feed functionality for testing environments
 */
contract MockV3Aggregator {
    uint8 public decimals;
    int256 public latestAnswer;

    /**
     * @notice Constructor initializes the aggregator with decimals and initial price
     * @param _decimals The number of decimals for the price feed
     * @param _initialAnswer The initial price value
     */
    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimals = _decimals;
        latestAnswer = _initialAnswer;
    }

    /**
     * @notice Returns the latest round data
     * @return roundId The round ID (always 0 for mock)
     * @return answer The latest price answer
     * @return startedAt The round start time (always 0 for mock)
     * @return updatedAt The round update time (always 0 for mock)
     * @return answeredInRound The round ID when the answer was computed (always 0 for mock)
     */
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (0, latestAnswer, 0, 0, 0);
    }

    /**
     * @notice Updates the latest price answer
     * @param _answer The new price value to set
     */
    function updateAnswer(int256 _answer) external {
        latestAnswer = _answer;
    }
}