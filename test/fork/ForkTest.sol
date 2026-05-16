// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../src/core/PredictionMarket.sol";
import "../../src/tokens/OutcomeToken.sol";
import "../../src/tokens/FeeVault.sol";
import "../../src/oracles/OracleAdapter.sol";

contract ForkTest is Test {
    address constant USDC         = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDC_WHALE   = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;

    PredictionMarket public market;
    OutcomeToken     public outcomeToken;
    FeeVault         public feeVault;
    OracleAdapter    public oracle;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC"));

        vm.startPrank(admin);
        outcomeToken = new OutcomeToken(admin);
        feeVault     = new FeeVault(IERC20(USDC), admin);
        oracle       = new OracleAdapter();

        PredictionMarket impl = new PredictionMarket();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(PredictionMarket.initialize, (
                admin, USDC, address(outcomeToken),
                address(feeVault), address(oracle)
            ))
        );
        market = PredictionMarket(address(proxy));
        outcomeToken.grantRole(outcomeToken.MINTER_ROLE(), address(market));
        feeVault.setMarket(address(market));
        vm.stopPrank();

        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(admin, 10_000e6);
        IERC20(USDC).transfer(alice, 5_000e6);
        vm.stopPrank();

        vm.prank(admin); IERC20(USDC).approve(address(market), type(uint256).max);
        vm.prank(alice); IERC20(USDC).approve(address(market), type(uint256).max);
    }

    function test_fork_chainlink_ethUsd_returnsRealPrice() public view {
        (int256 price, uint256 updatedAt) = oracle.getPrice(ETH_USD_FEED);
        assertGt(price, 100e8);
        assertLt(price, 100_000e8);
        assertGt(updatedAt, block.timestamp - 24 hours);
    }

    function test_fork_chainlink_stalenessCheck_passes() public view {
        int256 price = oracle.requireFreshPrice(ETH_USD_FEED, 24 hours);
        assertGt(price, 0);
    }

    function test_fork_createMarket_withRealChainlink() public {
        (int256 currentPrice,) = oracle.getPrice(ETH_USD_FEED);
        vm.prank(admin);
        uint256 marketId = market.createMarket(
            "Will ETH be above current price in 1 week?",
            ETH_USD_FEED,
            currentPrice,
            block.timestamp + 7 days,
            1000e6,
            1000e6
        );
        assertEq(marketId, 1);
        assertEq(uint8(market.getMarketState(1)), uint8(PredictionMarket.MarketState.Open));
    }
}
