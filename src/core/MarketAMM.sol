// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// YES * NO = k. Fee 0.3%.
library MarketAMM {
    uint256 public constant FEE_NUMERATOR   = 997;
    uint256 public constant FEE_DENOMINATOR = 1000;

    error InsufficientOutput();
    error ZeroLiquidity();
    error SlippageExceeded();

    struct Pool {
        uint256 reserveYes; 
        uint256 reserveNo;  
        uint256 totalShares;
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        if (reserveIn == 0 || reserveOut == 0) revert ZeroLiquidity();

        assembly {
            // amountInWithFee = amountIn * 997
            let amountInWithFee := mul(amountIn, 997)
            // numerator = amountInWithFee * reserveOut
            let numerator := mul(amountInWithFee, reserveOut)
            // denominator = reserveIn * 1000 + amountInWithFee
            let denominator := add(mul(reserveIn, 1000), amountInWithFee)
            // amountOut = numerator / denominator
            amountOut := div(numerator, denominator)
        }
    }

    function getAmountOutPure(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        return numerator / denominator;
    }

    function addLiquidity(
        Pool storage pool,
        uint256 yesAmount,
        uint256 noAmount
    ) internal returns (uint256 shares) {
        if (pool.totalShares == 0) {
            // initial liquidity
            shares = sqrt(yesAmount * noAmount);
        } else {
            uint256 sharesByYes = (yesAmount * pool.totalShares) / pool.reserveYes;
            uint256 sharesByNo  = (noAmount  * pool.totalShares) / pool.reserveNo;
            shares = sharesByYes < sharesByNo ? sharesByYes : sharesByNo;
        }
        pool.reserveYes  += yesAmount;
        pool.reserveNo   += noAmount;
        pool.totalShares += shares;
    }

    function removeLiquidity(
        Pool storage pool,
        uint256 shares
    ) internal returns (uint256 yesOut, uint256 noOut) {
        yesOut = (shares * pool.reserveYes) / pool.totalShares;
        noOut  = (shares * pool.reserveNo)  / pool.totalShares;
        pool.reserveYes  -= yesOut;
        pool.reserveNo   -= noOut;
        pool.totalShares -= shares;
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        assembly {
            y := x
            let z := add(div(x, 2), 1)
            for {} lt(z, y) {} {
                y := z
                z := div(add(div(x, z), z), 2)
            }
        }
    }
}