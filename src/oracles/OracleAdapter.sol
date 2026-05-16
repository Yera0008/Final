// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface IOracleAdapter {
    function getPrice(address feed) external view returns (int256 price, uint256 updatedAt);
    function requireFreshPrice(address feed, uint256 maxAge) external view returns (int256);
}

contract OracleAdapter is IOracleAdapter {
    error StalePrice(address feed, uint256 updatedAt, uint256 maxAge);
    error InvalidPrice(address feed, int256 price);

    /// @notice Возвращает цену и время обновления
    function getPrice(address feed)
        public view returns (int256 price, uint256 updatedAt)
    {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updateTime,
            uint80 answeredInRound
        ) = AggregatorV3Interface(feed).latestRoundData();

        require(answeredInRound >= roundId, "Stale round");
        require(answer > 0, "Negative price");

        return (answer, updateTime);
    }

    /// @notice Reverts если цена старше maxAge секунд
    function requireFreshPrice(
        address feed,
        uint256 maxAge
    ) external view returns (int256) {
        (int256 price, uint256 updatedAt) = getPrice(feed);
        if (block.timestamp - updatedAt > maxAge) {
            revert StalePrice(feed, updatedAt, maxAge);
        }
        return price;
    }
}