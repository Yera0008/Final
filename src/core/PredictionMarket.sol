// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import "../tokens/OutcomeToken.sol";
import "../tokens/FeeVault.sol";
import "../oracles/OracleAdapter.sol";
import {MarketAMM} from "./MarketAMM.sol";

contract PredictionMarket is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    ERC1155Holder,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using MarketAMM for MarketAMM.Pool;

    // Roles
    bytes32 public constant MARKET_CREATOR_ROLE = keccak256("MARKET_CREATOR_ROLE");
    bytes32 public constant RESOLVER_ROLE       = keccak256("RESOLVER_ROLE");
    bytes32 public constant PAUSER_ROLE         = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE       = keccak256("UPGRADER_ROLE");

    // State Machine 
    enum MarketState { Open, PendingResolution, Resolved, Disputed, Cancelled }
    enum Outcome     { Unresolved, YES, NO }

    //  Market struct 
    struct Market {
        uint256 id;
        string  question;
        address oracleFeed;       
        int256  resolutionPrice;  
        uint256 resolutionTime;   
        uint256 disputeWindow;    
        uint256 resolvedAt;
        MarketState state;
        Outcome outcome;
        MarketAMM.Pool pool;
        uint256 totalCollateral;  
    }

    // Storage
    IERC20       public collateral;   // USDC
    OutcomeToken public outcomeToken;
    FeeVault     public feeVault;
    OracleAdapter public oracle;

    uint256 public marketCount;
    mapping(uint256 => Market) public markets;
    mapping(address => mapping(uint256 => uint256)) public lpShares;

    uint256 public constant ORACLE_MAX_AGE   = 3600;   // 1 час
    uint256 public constant DISPUTE_WINDOW   = 2 days;
    uint256 public constant FEE_PERCENT      = 3;      // 0.3% (3/1000)

    // Events
    event MarketCreated(uint256 indexed id, string question, address feed, uint256 resolutionTime);
    event LiquidityAdded(uint256 indexed marketId, address indexed provider, uint256 shares);
    event LiquidityRemoved(uint256 indexed marketId, address indexed provider, uint256 shares);
    event OutcomeBought(uint256 indexed marketId, address indexed buyer, bool isYes, uint256 amountIn, uint256 amountOut);
    event MarketResolved(uint256 indexed marketId, Outcome outcome);
    event MarketDisputed(uint256 indexed marketId, address disputer);
    event Redeemed(uint256 indexed marketId, address indexed user, uint256 payout);

    // Errors
    error MarketNotOpen();
    error MarketNotResolvable();
    error AlreadyResolved();
    error SlippageTooHigh();
    error InsufficientShares();
    error DisputeWindowNotOver();
    error NotDisputable();
    error ZeroAmount();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address admin,
        address collateral_,
        address outcomeToken_,
        address feeVault_,
        address oracle_
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE,  admin);
        _grantRole(MARKET_CREATOR_ROLE, admin);
        _grantRole(RESOLVER_ROLE,       admin);
        _grantRole(PAUSER_ROLE,         admin);
        _grantRole(UPGRADER_ROLE,       admin);

        collateral   = IERC20(collateral_);
        outcomeToken = OutcomeToken(outcomeToken_);
        feeVault     = FeeVault(feeVault_);
        oracle       = OracleAdapter(oracle_);
    }

    // Market Creation 

    function createMarket(
        string calldata question,
        address oracleFeed,
        int256  resolutionPrice,
        uint256 resolutionTime,
        uint256 initialYes,
        uint256 initialNo
    ) external onlyRole(MARKET_CREATOR_ROLE) whenNotPaused returns (uint256 marketId) {
        require(resolutionTime > block.timestamp, "Invalid resolution time");
        require(initialYes > 0 && initialNo > 0, "Need initial liquidity");

        marketId = ++marketCount;
        Market storage m = markets[marketId];
        m.id              = marketId;
        m.question        = question;
        m.oracleFeed      = oracleFeed;
        m.resolutionPrice = resolutionPrice;
        m.resolutionTime  = resolutionTime;
        m.disputeWindow   = DISPUTE_WINDOW;
        m.state           = MarketState.Open;
        m.outcome         = Outcome.Unresolved;

        uint256 totalInitial = initialYes + initialNo;
        collateral.safeTransferFrom(msg.sender, address(this), totalInitial);
        m.totalCollateral += totalInitial;

        outcomeToken.mint(address(this), _yesId(marketId), initialYes, "");
        outcomeToken.mint(address(this), _noId(marketId),  initialNo,  "");

        uint256 shares = m.pool.addLiquidity(initialYes, initialNo);
        lpShares[msg.sender][marketId] += shares;

        emit MarketCreated(marketId, question, oracleFeed, resolutionTime);
        emit LiquidityAdded(marketId, msg.sender, shares);
    }

    // Liquidity 

    function addLiquidity(
        uint256 marketId,
        uint256 yesAmount,
        uint256 noAmount
    ) external nonReentrant whenNotPaused {
        Market storage m = _requireOpen(marketId);

        uint256 total = yesAmount + noAmount;
        collateral.safeTransferFrom(msg.sender, address(this), total);
        m.totalCollateral += total;

        outcomeToken.mint(address(this), _yesId(marketId), yesAmount, "");
        outcomeToken.mint(address(this), _noId(marketId),  noAmount,  "");

        uint256 shares = m.pool.addLiquidity(yesAmount, noAmount);
        lpShares[msg.sender][marketId] += shares;

        emit LiquidityAdded(marketId, msg.sender, shares);
    }

    function removeLiquidity(
        uint256 marketId,
        uint256 shares
    ) external nonReentrant {
        Market storage m = markets[marketId];
        if (lpShares[msg.sender][marketId] < shares) revert InsufficientShares();

        lpShares[msg.sender][marketId] -= shares;

        (uint256 yesOut, uint256 noOut) = m.pool.removeLiquidity(shares);

        outcomeToken.burn(address(this), _yesId(marketId), yesOut);
        outcomeToken.burn(address(this), _noId(marketId),  noOut);

        uint256 collateralOut = yesOut + noOut;
        m.totalCollateral -= collateralOut;
        collateral.safeTransfer(msg.sender, collateralOut);

        emit LiquidityRemoved(marketId, msg.sender, shares);
    }

    // Trading 

    function buyOutcome(
        uint256 marketId,
        bool    isYes,
        uint256 amountIn,
        uint256 minOut
    ) external nonReentrant whenNotPaused {
        if (amountIn == 0) revert ZeroAmount();
        Market storage m = _requireOpen(marketId);

        uint256 fee = (amountIn * FEE_PERCENT) / 1000;
        uint256 amountInAfterFee = amountIn - fee;

        uint256 reserveIn  = isYes ? m.pool.reserveNo  : m.pool.reserveYes;
        uint256 reserveOut = isYes ? m.pool.reserveYes : m.pool.reserveNo;

        uint256 amountOut = MarketAMM.getAmountOut(amountInAfterFee, reserveIn, reserveOut);
        if (amountOut < minOut) revert SlippageTooHigh();

        // Effects
        if (isYes) {
            m.pool.reserveYes -= amountOut;
            m.pool.reserveNo  += amountInAfterFee;
        } else {
            m.pool.reserveNo  -= amountOut;
            m.pool.reserveYes += amountInAfterFee;
        }
        m.totalCollateral += amountIn;

        collateral.safeTransferFrom(msg.sender, address(this), amountIn);

        collateral.approve(address(feeVault), fee);
        feeVault.depositFee(fee);

        uint256 tokenId = isYes ? _yesId(marketId) : _noId(marketId);
        outcomeToken.mint(msg.sender, tokenId, amountOut, "");

        emit OutcomeBought(marketId, msg.sender, isYes, amountIn, amountOut);
    }

    // Resolution 

    function resolveMarket(uint256 marketId) external onlyRole(RESOLVER_ROLE) {
        Market storage m = markets[marketId];
        if (m.state != MarketState.Open) revert MarketNotResolvable();
        if (block.timestamp < m.resolutionTime) revert MarketNotResolvable();

        int256 price = oracle.requireFreshPrice(m.oracleFeed, ORACLE_MAX_AGE);

        m.outcome   = price >= m.resolutionPrice ? Outcome.YES : Outcome.NO;
        m.state     = MarketState.PendingResolution;
        m.resolvedAt = block.timestamp;

        emit MarketResolved(marketId, m.outcome);
    }

    function disputeResolution(uint256 marketId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Market storage m = markets[marketId];
        if (m.state != MarketState.PendingResolution) revert NotDisputable();
        if (block.timestamp > m.resolvedAt + m.disputeWindow) revert DisputeWindowNotOver();

        m.state = MarketState.Disputed;
        emit MarketDisputed(marketId, msg.sender);
    }

    function finalizeResolution(uint256 marketId) external {
        Market storage m = markets[marketId];
        if (m.state != MarketState.PendingResolution) revert AlreadyResolved();
        if (block.timestamp <= m.resolvedAt + m.disputeWindow) revert DisputeWindowNotOver();

        m.state = MarketState.Resolved;
    }

    // Redemption

    function redeem(uint256 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        require(m.state == MarketState.Resolved, "Not resolved");

        uint256 winningTokenId = m.outcome == Outcome.YES
            ? _yesId(marketId)
            : _noId(marketId);

        uint256 userBalance = outcomeToken.balanceOf(msg.sender, winningTokenId);
        if (userBalance == 0) revert ZeroAmount();

        uint256 payout = userBalance;

        outcomeToken.burn(msg.sender, winningTokenId, userBalance);
        m.totalCollateral -= payout;

        collateral.safeTransfer(msg.sender, payout);
        emit Redeemed(marketId, msg.sender, payout);
    }

    // Helpers 

    function _yesId(uint256 marketId) internal pure returns (uint256) {
        return marketId * 2;
    }

    function _noId(uint256 marketId) internal pure returns (uint256) {
        return marketId * 2 + 1;
    }

    function _requireOpen(uint256 marketId) internal view returns (Market storage m) {
        m = markets[marketId];
        if (m.state != MarketState.Open) revert MarketNotOpen();
    }

    function getMarketState(uint256 marketId) external view returns (MarketState) {
    return markets[marketId].state;
}

function getMarketOutcome(uint256 marketId) external view returns (Outcome) {
    return markets[marketId].outcome;
}

function getMarketQuestion(uint256 marketId) external view returns (string memory) {
    return markets[marketId].question;
}

function getPoolReserves(uint256 marketId) external view returns (uint256 yes, uint256 no) {
    return (markets[marketId].pool.reserveYes, markets[marketId].pool.reserveNo);
}

    // Admin 

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

function supportsInterface(bytes4 interfaceId)
    public view override(AccessControlUpgradeable, ERC1155Holder)
    returns (bool)
{
    return super.supportsInterface(interfaceId);
}
}
