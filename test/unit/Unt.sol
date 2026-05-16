// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../src/core/PredictionMarket.sol";
import "../../src/tokens/OutcomeToken.sol";
import "../../src/tokens/FeeVault.sol";
import "../../src/oracles/OracleAdapter.sol";
import "../../src/oracles/MockAggregator.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("MockUSDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PredictionMarketTest is Test {
    PredictionMarket public market;
    OutcomeToken     public outcomeToken;
    FeeVault         public feeVault;
    OracleAdapter    public oracle;
    MockAggregator   public mockFeed;
    MockERC20        public usdc;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    uint256 constant INITIAL_YES = 1000e6;
    uint256 constant INITIAL_NO  = 1000e6;
    int256  constant ETH_PRICE   = 3000e8;

    function setUp() public {
        vm.startPrank(admin);

        usdc         = new MockERC20();
        outcomeToken = new OutcomeToken(admin);
        feeVault     = new FeeVault(IERC20(address(usdc)), admin);
        oracle       = new OracleAdapter();
        mockFeed     = new MockAggregator(ETH_PRICE, 8);

        PredictionMarket impl = new PredictionMarket();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(PredictionMarket.initialize, (
                admin,
                address(usdc),
                address(outcomeToken),
                address(feeVault),
                address(oracle)
            ))
        );
        market = PredictionMarket(address(proxy));

        outcomeToken.grantRole(outcomeToken.MINTER_ROLE(), address(market));
        feeVault.setMarket(address(market));

        usdc.mint(admin, 10_000e6);
        usdc.approve(address(market), type(uint256).max);

        vm.stopPrank();

        usdc.mint(alice, 5000e6);
        usdc.mint(bob,   5000e6);
        vm.prank(alice); usdc.approve(address(market), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(market), type(uint256).max);
    }


    function _createDefaultMarket() internal returns (uint256) {
        vm.prank(admin);
        return market.createMarket(
            "Will ETH > $3000 at end of month?",
            address(mockFeed),
            ETH_PRICE,
            block.timestamp + 7 days,
            INITIAL_YES,
            INITIAL_NO
        );
    }

    function _resolveYes(uint256 marketId) internal {
        vm.warp(block.timestamp + 8 days);
        mockFeed.setAnswer(3500e8);
        vm.prank(admin);
        market.resolveMarket(marketId);
        vm.warp(block.timestamp + 3 days);
        market.finalizeResolution(marketId);
    }

    function _resolveNo(uint256 marketId) internal {
        vm.warp(block.timestamp + 8 days);
        mockFeed.setAnswer(2500e8);
        vm.prank(admin);
        market.resolveMarket(marketId);
        vm.warp(block.timestamp + 3 days);
        market.finalizeResolution(marketId);
    }


    function test_createMarket_success() public {
        uint256 id = _createDefaultMarket();
        assertEq(id, 1);
        assertEq(uint8(market.getMarketState(1)), uint8(PredictionMarket.MarketState.Open));
    }

    function test_createMarket_setsQuestion() public {
        _createDefaultMarket();
        assertEq(market.getMarketQuestion(1), "Will ETH > $3000 at end of month?");
    }

    function test_createMarket_incrementsCount() public {
        _createDefaultMarket();
        _createDefaultMarket();
        assertEq(market.marketCount(), 2);
    }

    function test_createMarket_revertsIfNotCreator() public {
        vm.prank(alice);
        vm.expectRevert();
        market.createMarket("Q", address(mockFeed), ETH_PRICE, block.timestamp + 7 days, INITIAL_YES, INITIAL_NO);
    }

    function test_createMarket_revertsIfInvalidTime() public {
        vm.prank(admin);
        vm.expectRevert("Invalid resolution time");
        market.createMarket("Q", address(mockFeed), ETH_PRICE, block.timestamp - 1, INITIAL_YES, INITIAL_NO);
    }

    function test_createMarket_revertsIfZeroLiquidity() public {
        vm.prank(admin);
        vm.expectRevert("Need initial liquidity");
        market.createMarket("Q", address(mockFeed), ETH_PRICE, block.timestamp + 7 days, 0, 0);
    }

    function test_createMarket_lpSharesAssigned() public {
        _createDefaultMarket();
        assertGt(market.lpShares(admin, 1), 0);
    }


    function test_buyYes_success() public {
        _createDefaultMarket();
        vm.prank(alice);
        market.buyOutcome(1, true, 100e6, 0);
        assertGt(outcomeToken.balanceOf(alice, 2), 0);
    }

    function test_buyNo_success() public {
        _createDefaultMarket();
        vm.prank(alice);
        market.buyOutcome(1, false, 100e6, 0);
        assertGt(outcomeToken.balanceOf(alice, 3), 0);
    }

    function test_buy_revertsSlippage() public {
        _createDefaultMarket();
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.SlippageTooHigh.selector);
        market.buyOutcome(1, true, 100e6, type(uint256).max);
    }

    function test_buy_revertsZeroAmount() public {
        _createDefaultMarket();
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        market.buyOutcome(1, true, 0, 0);
    }

    function test_buy_feeGoesToVault() public {
        _createDefaultMarket();
        uint256 before = usdc.balanceOf(address(feeVault));
        vm.prank(alice);
        market.buyOutcome(1, true, 1000e6, 0);
        assertEq(usdc.balanceOf(address(feeVault)) - before, 3e6);
    }

    function test_buy_revertsOnClosedMarket() public {
        _createDefaultMarket();
        _resolveYes(1);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.MarketNotOpen.selector);
        market.buyOutcome(1, true, 100e6, 0);
    }

    function test_buy_deductsCollateral() public {
        _createDefaultMarket();
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        market.buyOutcome(1, true, 100e6, 0);
        assertEq(before - usdc.balanceOf(alice), 100e6);
    }

    function test_buyYes_updatesReserves() public {
        _createDefaultMarket();
        (uint256 yesBefore, uint256 noBefore) = market.getPoolReserves(1);
        vm.prank(alice);
        market.buyOutcome(1, true, 100e6, 0);
        (uint256 yesAfter, uint256 noAfter) = market.getPoolReserves(1);
        assertLt(yesAfter, yesBefore);
        assertGt(noAfter, noBefore);
    }


    function test_addLiquidity_success() public {
        _createDefaultMarket();
        vm.prank(alice);
        market.addLiquidity(1, 500e6, 500e6);
        assertGt(market.lpShares(alice, 1), 0);
    }

    function test_addLiquidity_revertsOnClosedMarket() public {
        _createDefaultMarket();
        _resolveYes(1);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.MarketNotOpen.selector);
        market.addLiquidity(1, 500e6, 500e6);
    }

    function test_removeLiquidity_success() public {
        _createDefaultMarket();
        uint256 shares = market.lpShares(admin, 1);
        uint256 before = usdc.balanceOf(admin);
        vm.prank(admin);
        market.removeLiquidity(1, shares);
        assertGt(usdc.balanceOf(admin), before);
        assertEq(market.lpShares(admin, 1), 0);
    }

    function test_removeLiquidity_revertsInsufficientShares() public {
        _createDefaultMarket();
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.InsufficientShares.selector);
        market.removeLiquidity(1, 1);
    }

    function test_removeLiquidity_partialShares() public {
        _createDefaultMarket();
        uint256 shares = market.lpShares(admin, 1);
        vm.prank(admin);
        market.removeLiquidity(1, shares / 2);
        assertEq(market.lpShares(admin, 1), shares - shares / 2);
    }


    function test_resolveMarket_YES() public {
        _createDefaultMarket();
        vm.warp(block.timestamp + 8 days);
        mockFeed.setAnswer(3500e8);
        vm.prank(admin);
        market.resolveMarket(1);
        assertEq(uint8(market.getMarketOutcome(1)), uint8(PredictionMarket.Outcome.YES));
        assertEq(uint8(market.getMarketState(1)), uint8(PredictionMarket.MarketState.PendingResolution));
    }

    function test_resolveMarket_NO() public {
        _createDefaultMarket();
        vm.warp(block.timestamp + 8 days);
        mockFeed.setAnswer(2500e8);
        vm.prank(admin);
        market.resolveMarket(1);
        assertEq(uint8(market.getMarketOutcome(1)), uint8(PredictionMarket.Outcome.NO));
    }

    function test_resolveMarket_revertsStalePrice() public {
        _createDefaultMarket();
        vm.warp(block.timestamp + 8 days);
        mockFeed.setUpdatedAt(block.timestamp - 7200);
        vm.prank(admin);
        vm.expectRevert();
        market.resolveMarket(1);
    }

    function test_resolveMarket_revertsTooEarly() public {
        _createDefaultMarket();
        vm.prank(admin);
        vm.expectRevert(PredictionMarket.MarketNotResolvable.selector);
        market.resolveMarket(1);
    }

    function test_resolveMarket_revertsIfNotResolver() public {
        _createDefaultMarket();
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        vm.expectRevert();
        market.resolveMarket(1);
    }

    function test_finalizeResolution_success() public {
        _createDefaultMarket();
        vm.warp(block.timestamp + 8 days);
        mockFeed.setAnswer(3500e8);
        vm.prank(admin);
        market.resolveMarket(1);
        vm.warp(block.timestamp + 3 days);
        market.finalizeResolution(1);
        assertEq(uint8(market.getMarketState(1)), uint8(PredictionMarket.MarketState.Resolved));
    }

    function test_finalizeResolution_revertsBeforeWindow() public {
        _createDefaultMarket();
        vm.warp(block.timestamp + 8 days);
        mockFeed.setAnswer(3500e8);
        vm.prank(admin);
        market.resolveMarket(1);
        vm.expectRevert(PredictionMarket.DisputeWindowNotOver.selector);
        market.finalizeResolution(1);
    }


    function test_redeem_winnerYES() public {
        _createDefaultMarket();
        vm.prank(alice);
        market.buyOutcome(1, true, 500e6, 0);
        uint256 yesBalance = outcomeToken.balanceOf(alice, 2);
        _resolveYes(1);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        market.redeem(1);
        assertEq(usdc.balanceOf(alice), before + yesBalance);
        assertEq(outcomeToken.balanceOf(alice, 2), 0);
    }

    function test_redeem_winnerNO() public {
        _createDefaultMarket();
        vm.prank(bob);
        market.buyOutcome(1, false, 500e6, 0);
        uint256 noBalance = outcomeToken.balanceOf(bob, 3);
        _resolveNo(1);
        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        market.redeem(1);
        assertEq(usdc.balanceOf(bob), before + noBalance);
    }

    function test_redeem_loserRevertsZeroAmount() public {
        _createDefaultMarket();
        vm.prank(bob);
        market.buyOutcome(1, false, 100e6, 0);
        _resolveYes(1);
        vm.prank(bob);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        market.redeem(1);
    }

    function test_redeem_revertsIfNotResolved() public {
        _createDefaultMarket();
        vm.prank(alice);
        market.buyOutcome(1, true, 100e6, 0);
        vm.prank(alice);
        vm.expectRevert("Not resolved");
        market.redeem(1);
    }

    function test_redeem_burnsTokens() public {
        _createDefaultMarket();
        vm.prank(alice);
        market.buyOutcome(1, true, 100e6, 0);
        _resolveYes(1);
        vm.prank(alice);
        market.redeem(1);
        assertEq(outcomeToken.balanceOf(alice, 2), 0);
    }


    function test_pause_preventsTrading() public {
        _createDefaultMarket();
        vm.prank(admin);
        market.pause();
        vm.prank(alice);
        vm.expectRevert();
        market.buyOutcome(1, true, 100e6, 0);
    }

    function test_unpause_allowsTrading() public {
        _createDefaultMarket();
        vm.prank(admin);
        market.pause();
        vm.prank(admin);
        market.unpause();
        vm.prank(alice);
        market.buyOutcome(1, true, 100e6, 0);
        assertGt(outcomeToken.balanceOf(alice, 2), 0);
    }

    function test_pause_revertsIfNotPauser() public {
        vm.prank(alice);
        vm.expectRevert();
        market.pause();
    }

    function test_disputeResolution_success() public {
    _createDefaultMarket();
    vm.warp(block.timestamp + 8 days);
    mockFeed.setAnswer(3500e8);
    vm.prank(admin);
    market.resolveMarket(1);

    vm.prank(admin);
    market.disputeResolution(1);
    assertEq(uint8(market.getMarketState(1)), uint8(PredictionMarket.MarketState.Disputed));
}

function test_disputeResolution_revertsIfNotPendingResolution() public {
    _createDefaultMarket();
    vm.prank(admin);
    vm.expectRevert(PredictionMarket.NotDisputable.selector);
    market.disputeResolution(1);
}
}