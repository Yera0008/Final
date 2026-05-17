import {
  BigInt,
  Bytes,
} from "@graphprotocol/graph-ts";

import {
  MarketCreated,
  OutcomeBought,
  LiquidityAdded,
  LiquidityRemoved,
  MarketResolved,
  Redeemed,
} from "../generated/PredictionMarket/PredictionMarket";

import {
  Market,
  Trade,
  LiquidityEvent,
  Redemption,
  MarketStats,
} from "../generated/schema";

// ── Helpers ──────────────────────────────────────────────────────────────────

function getOrCreateMarketStats(marketId: string, timestamp: BigInt): MarketStats {
  let stats = MarketStats.load(marketId);
  if (stats == null) {
    stats = new MarketStats(marketId);
    stats.market = marketId;
    stats.totalTrades = BigInt.fromI32(0);
    stats.totalVolumeIn = BigInt.fromI32(0);
    stats.totalFeesCollected = BigInt.fromI32(0);
    stats.uniqueTraders = BigInt.fromI32(0);
    stats.lastUpdated = timestamp;
  }
  return stats as MarketStats;
}

function outcomeToString(outcome: i32): string {
  if (outcome == 1) return "YES";
  if (outcome == 2) return "NO";
  return "Unresolved";
}

// ── Handlers ─────────────────────────────────────────────────────────────────

export function handleMarketCreated(event: MarketCreated): void {
  let marketId = event.params.id.toString();

  let market = new Market(marketId);
  market.question        = event.params.question;
  market.oracleFeed      = event.params.feed;
  market.resolutionPrice = BigInt.fromI32(0);
  market.resolutionTime  = event.params.resolutionTime;
  market.state           = "Open";
  market.outcome         = "Unresolved";
  market.createdAt       = event.block.timestamp;
  market.totalCollateral = BigInt.fromI32(0);
  market.save();

  let stats = getOrCreateMarketStats(marketId, event.block.timestamp);
  stats.save();
}

export function handleOutcomeBought(event: OutcomeBought): void {
  let marketId = event.params.marketId.toString();
  let tradeId  = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();

  let trade = new Trade(tradeId);
  trade.market      = marketId;
  trade.buyer       = event.params.buyer;
  trade.isYes       = event.params.isYes;
  trade.amountIn    = event.params.amountIn;
  trade.amountOut   = event.params.amountOut;
  trade.timestamp   = event.block.timestamp;
  trade.blockNumber = event.block.number;
  trade.save();

  let stats = getOrCreateMarketStats(marketId, event.block.timestamp);
  stats.totalTrades   = stats.totalTrades.plus(BigInt.fromI32(1));
  stats.totalVolumeIn = stats.totalVolumeIn.plus(event.params.amountIn);
  // fee = amountIn * 3 / 1000
  let fee = event.params.amountIn.times(BigInt.fromI32(3)).div(BigInt.fromI32(1000));
  stats.totalFeesCollected = stats.totalFeesCollected.plus(fee);
  stats.lastUpdated = event.block.timestamp;
  stats.save();

  let market = Market.load(marketId);
  if (market != null) {
    market.totalCollateral = market.totalCollateral.plus(event.params.amountIn);
    market.save();
  }
}

export function handleLiquidityAdded(event: LiquidityAdded): void {
  let eventId = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();

  let liq = new LiquidityEvent(eventId);
  liq.market    = event.params.marketId.toString();
  liq.provider  = event.params.provider;
  liq.shares    = event.params.shares;
  liq.type      = "ADD";
  liq.timestamp = event.block.timestamp;
  liq.save();
}

export function handleLiquidityRemoved(event: LiquidityRemoved): void {
  let eventId = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();

  let liq = new LiquidityEvent(eventId);
  liq.market    = event.params.marketId.toString();
  liq.provider  = event.params.provider;
  liq.shares    = event.params.shares;
  liq.type      = "REMOVE";
  liq.timestamp = event.block.timestamp;
  liq.save();
}

export function handleMarketResolved(event: MarketResolved): void {
  let marketId = event.params.marketId.toString();
  let market   = Market.load(marketId);
  if (market == null) return;

  market.state   = "PendingResolution";
  market.outcome = outcomeToString(event.params.outcome);
  market.save();
}

export function handleRedeemed(event: Redeemed): void {
  let redemptionId = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();

  let redemption = new Redemption(redemptionId);
  redemption.market    = event.params.marketId.toString();
  redemption.user      = event.params.user;
  redemption.payout    = event.params.payout;
  redemption.timestamp = event.block.timestamp;
  redemption.save();
}