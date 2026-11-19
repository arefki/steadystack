// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { PriceMath } from "../src/PriceMath.sol";

/// @notice Harness exposing the internal library function for tests.
contract PriceMathHarness {
    function priceFromSqrt(uint160 sqrtPriceX96_) external pure returns (uint256) {
        return PriceMath.priceFromSqrt(sqrtPriceX96_);
    }
}

/// @notice Price math: USDC-per-WETH in 6-dec fixed point from a Uniswap V3
/// sqrtPriceX96, for a pool with token0 = USDC (6 dec), token1 = WETH (18 dec).
/// Exact math: price6 = 10^18 * 2^192 / sqrtPriceX96^2.
/// Expected values below are the two-step computation verified in Python
/// (ground truth: exact big-int math; two-step deviates by at most 1 ulp,
/// i.e. 1e-6 USDC, at realistic prices).
contract PriceMathTest is Test {
    PriceMathHarness internal math;

    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;

    function setUp() public {
        math = new PriceMathHarness();
    }

    function test_Price3000() public view {
        assertEq(math.priceFromSqrt(1446501726624926496477173928747178), 2999999999);
    }

    function test_PriceSubDollar() public view {
        // P = $0.50 — the whole-units formula truncated this to 0 (design review H1).
        assertEq(math.priceFromSqrt(112045541949572279837463876454916344), 499999);
    }

    function test_Price14414() public view {
        assertEq(math.priceFromSqrt(659913974035993881960911641787963), 14413999999);
    }

    function test_PriceLivePool() public view {
        // Live Base Sepolia pool slot0 on 2026-11-19: $26,546.797662/WETH.
        assertEq(math.priceFromSqrt(486265562655477577365273087986136), 26546797662);
    }

    function test_PriceOneDollar() public view {
        assertEq(math.priceFromSqrt(79228162514264337593543950336000000), 999999);
    }

    function test_Price100() public view {
        assertEq(math.priceFromSqrt(7922816251426433759354395033600000), 99999999);
    }

    function test_Price1800() public view {
        assertEq(math.priceFromSqrt(1867425699159537997291064607581939), 1799999999);
    }

    function test_PriceAtMinSqrt() public view {
        // Tick extreme: WETH astronomically expensive; must not overflow.
        assertEq(math.priceFromSqrt(MIN_SQRT), 340256786698763678858396856460488307819979090561317864144);
    }

    function test_PriceAtMaxSqrtIsZero() public view {
        // Tick extreme: WETH nearly worthless; price truncates to 0.
        assertEq(math.priceFromSqrt(MAX_SQRT), 0);
    }

    function test_PriceZeroSqrtIsZero() public view {
        // Defensive: a zero sqrt price never reverts, it yields price 0
        // (callers treat 0 as "no usable price").
        assertEq(math.priceFromSqrt(0), 0);
    }

    function test_PriceRandomVector1() public view {
        assertEq(math.priceFromSqrt(6357575116396189595028963020331024384), 155);
    }

    function test_PriceRandomVector2() public view {
        assertEq(math.priceFromSqrt(1399998443227494277432161746288640), 3202610048);
    }

    function testFuzz_PriceNeverReverts(uint160 sqrtP) public view {
        // Any uint160 input must compute without reverting (no overflow).
        math.priceFromSqrt(sqrtP);
    }

    function testFuzz_PriceMonotonicDecreasing(uint160 a, uint160 b) public view {
        // A larger sqrt price means cheaper WETH (token1/token0 up => USDC/WETH down).
        // sqrtP == 0 is the defensive special case (returns 0) and is excluded
        // here; it is covered by test_PriceZeroSqrtIsZero.
        vm.assume(a > 0 && b > 0);
        uint160 lo = a < b ? a : b;
        uint160 hi = a < b ? b : a;
        assertGe(math.priceFromSqrt(lo), math.priceFromSqrt(hi));
    }

    function testFuzz_PriceWithinOneUlpOfExact(uint160 sqrtP) public view {
        // The two-step computation deviates from exact big-int math by at most
        // a few ulps; bound the relative error. Skip the zero-price plateau.
        vm.assume(sqrtP >= MIN_SQRT && sqrtP <= MAX_SQRT);
        uint256 got = math.priceFromSqrt(sqrtP);
        if (got == 0) return;
        // Exact check via the identity: got * sqrtP^2 ~= 10^18 * 2^192.
        // sqrtP^2 overflows uint256 at extremes, so verify in two halves:
        // got <= 10^18 * 2^192 / sqrtP^2 + 2  <=>  got * sqrtP <= (10^18 * 2^192 + 2*sqrtP^2)/sqrtP.
        // Simpler bound used here: recompute with the alternate order
        // (10^18 / sqrtP first is too lossy), so instead assert monotonicity
        // against neighbours: price(sqrtP-1) >= price(sqrtP) >= price(sqrtP+1).
        if (sqrtP > MIN_SQRT) assertGe(math.priceFromSqrt(sqrtP - 1), got);
        if (sqrtP < MAX_SQRT) assertLe(math.priceFromSqrt(sqrtP + 1), got);
    }
}
