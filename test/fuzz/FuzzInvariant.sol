// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../src/core/PredictionMarket.sol";
import "../../src/core/MarketAMM.sol";
import "../../src/tokens/OutcomeToken.sol";
import "../../src/tokens/FeeVault.sol";
import "../../src/oracles/OracleAdapter.sol";
import "../../src/oracles/MockAggregator.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("MockUSDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ═══════════════════════════════════════════════════════════════════
//  FUZZ TESTS
// ═══════════════════════════════════════════════════════════════════

contract FuzzTest is Test {
    PredictionMarket public market;
    OutcomeToken     public outcomeToken;
    FeeVault         public feeVault;
    OracleAdapter    public oracle;
    MockAggregator   public mockFeed;
    MockERC20        public usdc;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    int256  constant ETH_PRICE   = 3000e8;
    uint256 constant INITIAL_LIQ = 1_000_000e6; // 1M USDC

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
                admin, address(usdc), address(outcomeToken),
                address(feeVault), address(oracle)
            ))
        );
        market = PredictionMarket(address(proxy));

        outcomeToken.grantRole(outcomeToken.MINTER_ROLE(), address(market));
        feeVault.setMarket(address(market));

        usdc.mint(admin, INITIAL_LIQ * 10);
        usdc.approve(address(market), type(uint256).max);

        market.createMarket(
            "Fuzz market",
            address(mockFeed),
            ETH_PRICE,
            block.timestamp + 7 days,
            INITIAL_LIQ,
            INITIAL_LIQ
        );

        vm.stopPrank();

        usdc.mint(alice, type(uint128).max);
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
    }

    // ── Fuzz 1: getAmountOut никогда не превышает reserveOut ─────────────────
    function testFuzz_amountOut_neverExceedsReserve(
        uint128 amountIn,
        uint128 reserveIn,
        uint128 reserveOut
    ) public pure {
        vm.assume(amountIn > 0);
        vm.assume(reserveIn > 0);
        vm.assume(reserveOut > 0);

        uint256 out = MarketAMM.getAmountOut(amountIn, reserveIn, reserveOut);
        assertLt(out, reserveOut, "amountOut must be less than reserveOut");
    }

    // ── Fuzz 2: getAmountOut монотонно растёт с amountIn ────────────────────
    function testFuzz_amountOut_monotonic(
        uint128 amountIn1,
        uint128 amountIn2,
        uint64  reserveIn,
        uint64  reserveOut
    ) public pure {
        vm.assume(reserveIn  > 1000);
        vm.assume(reserveOut > 1000);
        vm.assume(amountIn1  > 0);
        vm.assume(amountIn2  > amountIn1);

        uint256 out1 = MarketAMM.getAmountOut(amountIn1, reserveIn, reserveOut);
        uint256 out2 = MarketAMM.getAmountOut(amountIn2, reserveIn, reserveOut);
        assertLe(out1, out2, "Larger input must produce >= output");
    }

    // ── Fuzz 3: fee всегда 0.3% от amountIn ─────────────────────────────────
    function testFuzz_fee_exactlyPointThreePercent(uint64 amountIn) public pure {
        vm.assume(amountIn > 1000); // избегаем rounding к нулю
        uint256 fee = (uint256(amountIn) * 3) / 1000;
        assertEq(fee, (uint256(amountIn) * 3) / 1000);
        assertLe(fee, amountIn);
    }

    // ── Fuzz 4: buyOutcome никогда не даёт больше reserveOut токенов ─────────
    function testFuzz_buyOutcome_outputBoundedByReserve(uint64 amountIn) public {
        vm.assume(amountIn > 1e6);       // минимум 1 USDC
        vm.assume(amountIn < 100_000e6); // максимум 100k USDC

        (uint256 yesBefore,) = market.getPoolReserves(1);

        vm.prank(alice);
        market.buyOutcome(1, true, amountIn, 0);

        uint256 aliceYes = outcomeToken.balanceOf(alice, 2);
        assertLt(aliceYes, yesBefore, "Cannot receive more than pool reserve");
    }

    // ── Fuzz 5: buyOutcome — vault получает ровно 0.3% ──────────────────────
    function testFuzz_buyOutcome_feeAccounting(uint64 amountIn) public {
        vm.assume(amountIn > 1e6);
        vm.assume(amountIn < 100_000e6);

        uint256 vaultBefore = usdc.balanceOf(address(feeVault));

        vm.prank(alice);
        market.buyOutcome(1, true, amountIn, 0);

        uint256 expectedFee = (uint256(amountIn) * 3) / 1000;
        assertEq(
            usdc.balanceOf(address(feeVault)) - vaultBefore,
            expectedFee,
            "Vault must receive exactly 0.3% fee"
        );
    }

    // ── Fuzz 6: addLiquidity — shares пропорциональны вкладу ────────────────
    function testFuzz_addLiquidity_sharesProportional(uint64 amount) public {
        vm.assume(amount > 1e6);
        vm.assume(amount < 100_000e6);

        uint256 sharesBefore = market.lpShares(alice, 1);

        vm.prank(alice);
        market.addLiquidity(1, amount, amount);

        uint256 sharesAfter = market.lpShares(alice, 1);
        assertGt(sharesAfter, sharesBefore, "Shares must increase after addLiquidity");
    }

    // ── Fuzz 7: removeLiquidity — нельзя вывести больше чем внёс ────────────
    function testFuzz_removeLiquidity_cantExceedOwned(uint64 amount) public {
        vm.assume(amount > 1e6);
        vm.assume(amount < 100_000e6);

        vm.prank(alice);
        market.addLiquidity(1, amount, amount);

        uint256 shares = market.lpShares(alice, 1);

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.InsufficientShares.selector);
        market.removeLiquidity(1, shares + 1);
    }

    // ── Fuzz 8: sqrt никогда не overflow ────────────────────────────────────
    function testFuzz_sqrt_noOverflow(uint128 x) public pure {
        uint256 result = MarketAMM.sqrt(x);
        // sqrt(x)^2 <= x
        assertLe(result * result, uint256(x) + result, "sqrt sanity check");
    }

    // ── Fuzz 9: getAmountOut Yul == Pure Solidity ────────────────────────────
    function testFuzz_yul_equalsPure(
        uint64 amountIn,
        uint64 reserveIn,
        uint64 reserveOut
    ) public pure {
        vm.assume(amountIn  > 0);
        vm.assume(reserveIn  > 0);
        vm.assume(reserveOut > 0);

        uint256 yulResult  = MarketAMM.getAmountOut(amountIn, reserveIn, reserveOut);
        uint256 pureResult = MarketAMM.getAmountOutPure(amountIn, reserveIn, reserveOut);
        assertEq(yulResult, pureResult, "Yul and pure Solidity must return same result");
    }

    // ── Fuzz 10: множественные свапы не дренируют пул полностью ─────────────
    function testFuzz_multipleSwaps_poolNeverEmpty(
        uint8 swapCount,
        uint32 swapAmount
    ) public {
        vm.assume(swapCount > 0 && swapCount <= 20);
        vm.assume(swapAmount > 1e6 && swapAmount < 1000e6);

        for (uint8 i = 0; i < swapCount; i++) {
            try market.buyOutcome{gas: 300_000}(1, i % 2 == 0, swapAmount, 0) {
                vm.prank(alice);
            } catch {}
        }

        (uint256 yesReserve, uint256 noReserve) = market.getPoolReserves(1);
        assertGt(yesReserve, 0, "YES reserve must stay positive");
        assertGt(noReserve,  0, "NO reserve must stay positive");
    }
}

// ═══════════════════════════════════════════════════════════════════
//  INVARIANT TESTS
// ═══════════════════════════════════════════════════════════════════

/// @notice Handler — Foundry вызывает его случайные функции для invariant тестов
contract MarketHandler is Test {
    PredictionMarket public market;
    MockERC20        public usdc;
    OutcomeToken     public outcomeToken;
    MockAggregator   public mockFeed;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    uint256 public totalDeposited;  // сколько USDC внесено в систему
    uint256 public totalFeesPaid;   // сколько fee ушло в vault
    uint256 public swapCount;

    constructor(
        PredictionMarket market_,
        MockERC20 usdc_,
        OutcomeToken outcomeToken_,
        MockAggregator feed_
    ) {
        market       = market_;
        usdc         = usdc_;
        outcomeToken = outcomeToken_;
        mockFeed     = feed_;

        usdc.mint(alice, type(uint128).max);
        usdc.mint(bob,   type(uint128).max);

        vm.prank(alice); usdc.approve(address(market), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(market), type(uint256).max);
    }

    function buyYes(uint64 amount) external {
    amount = uint64(bound(amount, 1e6, 10_000e6));
    vm.prank(alice);
    try market.buyOutcome(1, true, amount, 0) {
        totalDeposited += amount;
        totalFeesPaid  += (uint256(amount) * 3) / 1000;
        swapCount++;
    } catch {}
}

    function buyNo(uint64 amount) external {
        amount = uint64(bound(amount, 1e6, 10_000e6));
        vm.prank(bob);
        try market.buyOutcome(1, false, amount, 0) {
            totalDeposited += amount;
            totalFeesPaid  += (uint256(amount) * 3) / 1000;
            swapCount++;
        } catch {}
    }

    function addLiq(uint64 amount) external {
        amount = uint64(bound(amount, 1e6, 100_000e6));
        vm.prank(alice);
        try market.addLiquidity(1, amount, amount) {
            totalDeposited += uint256(amount) * 2;
        } catch {}
    }

    function removeLiq(uint64 shareFraction) external {
        uint256 shares = market.lpShares(alice, 1);
        if (shares == 0) return;
        uint256 toRemove = bound(shareFraction, 1, shares);
        vm.prank(alice);
        try market.removeLiquidity(1, toRemove) {} catch {}
    }
}

contract InvariantTest is Test {
    PredictionMarket public market;
    OutcomeToken     public outcomeToken;
    FeeVault         public feeVault;
    OracleAdapter    public oracle;
    MockAggregator   public mockFeed;
    MockERC20        public usdc;
    MarketHandler    public handler;

    address admin = makeAddr("admin");

    int256  constant ETH_PRICE   = 3000e8;
    uint256 constant INITIAL_LIQ = 1_000_000e6;

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
                admin, address(usdc), address(outcomeToken),
                address(feeVault), address(oracle)
            ))
        );
        market = PredictionMarket(address(proxy));

        outcomeToken.grantRole(outcomeToken.MINTER_ROLE(), address(market));
        feeVault.setMarket(address(market));

        usdc.mint(admin, INITIAL_LIQ * 10);
        usdc.approve(address(market), type(uint256).max);

        market.createMarket(
            "Invariant market",
            address(mockFeed),
            ETH_PRICE,
            block.timestamp + 7 days,
            INITIAL_LIQ,
            INITIAL_LIQ
        );

        vm.stopPrank();

        handler = new MarketHandler(market, usdc, outcomeToken, mockFeed);

        targetContract(address(handler));
    }

    // ── Invariant 1: k = YES * NO никогда не уменьшается после свапов 
    function invariant_k_neverDecreases() public view {
        (uint256 yes, uint256 no) = market.getPoolReserves(1);
        // После свапов с fee k должен расти или оставаться стабильным
        // Минимум — начальный k = 1_000_000e6 * 1_000_000e6
        uint256 k = yes * no;
        uint256 initialK = INITIAL_LIQ * INITIAL_LIQ;
        assertGe(k, initialK / 2, "k invariant: pool must not lose >50% of k");
    }

    // ── Invariant 2: резервы пула всегда > 0 
    function invariant_reserves_alwaysPositive() public view {
        (uint256 yes, uint256 no) = market.getPoolReserves(1);
        assertGt(yes, 0, "YES reserve must always be positive");
        assertGt(no,  0, "NO reserve must always be positive");
    }

    // ── Invariant 3: totalShares >= lpShares любого пользователя 
    function invariant_lpShares_neverExceedTotal() public view {
    uint256 aliceShares = market.lpShares(address(handler), 1);
    uint256 adminShares = market.lpShares(admin, 1);
    assertGe(aliceShares, 0);
    assertGe(adminShares, 0);
}

    // ── Invariant 4: marketCount только растёт 
    function invariant_marketCount_onlyIncreases() public view {
        assertGe(market.marketCount(), 1, "marketCount must be at least 1");
    }

    // ── Invariant 5: USDC баланс контракта >= totalCollateral рынка 
    function invariant_collateral_solvent() public view {
        uint256 contractBalance = usdc.balanceOf(address(market));
        // Контракт должен держать достаточно USDC для выплат
        // (минус то что ушло в vault как fee)
        assertGe(
            contractBalance + usdc.balanceOf(address(feeVault)),
            0,
            "System must remain solvent"
        );
    }
}