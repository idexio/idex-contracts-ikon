// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

/**
 * @notice Enums definitions
 */

// Internal - liquidations //

enum LiquidationType {
  Exited,
  InMaintenance
  // TODO SystemRecovery
  // TODO Dust
}

// Order book //

enum OrderSelfTradePrevention {
  // Decrement and cancel
  dc,
  // Cancel oldest
  co,
  // Cancel newest
  cn,
  // Cancel both
  cb
}

enum OrderSide {
  Buy,
  Sell
}

enum OrderTimeInForce {
  // Good until cancelled
  gtc,
  // Good until time
  gtt,
  // Immediate or cancel
  ioc,
  // Fill or kill
  fok
}

enum OrderType {
  Market,
  Limit,
  LimitMaker,
  StopLoss,
  StopLossLimit,
  TakeProfit,
  TakeProfitLimit
}
