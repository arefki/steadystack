// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

/// @title PriceMath — Uniswap V3 sqrtPriceX96 -> USDC-per-WETH, 6-dec fixed point.
/// @notice For a pool with token0 = USDC (6 decimals) and token1 = WETH (18 decimals):
///     price6 = 10^18 * 2^192 / sqrtPriceX96^2
/// The naive form squares sqrtPriceX96, which overflows uint256 at tick extremes
/// (sqrtPriceX96 is uint160, so the square reaches 2^320). This implementation
/// never squares: a = 2^192 / sqrtP, then a * 10^18 / sqrtP. Bounds: a <= 2^192
/// (at sqrtP = 1) so a * 10^18 <= 2^192 * 10^18 < 2^252 < uint256 max.
/// Verified against exact big-int math in Python: deviates by at most 1 ulp
/// (1e-6 USDC) at realistic prices; see test/PriceMath.t.sol.
library PriceMath {
    function priceFromSqrt(uint160 sqrtPriceX96_) internal pure returns (uint256) {
        if (sqrtPriceX96_ == 0) return 0;
        // Divide-before-multiply is INTENTIONAL here: squaring sqrtPriceX96
        // would overflow uint256 at tick extremes. The two-step form loses at
        // most 1 ulp (verified against exact big-int math in Python).
        uint256 a = (uint256(1) << 192) / sqrtPriceX96_;
        // forge-lint: disable-next-line(divide-before-multiply)
        return (a * 1e18) / sqrtPriceX96_;
    }
}
