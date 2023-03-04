// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

/**
 * @notice Enums definitions
 */

// Automatic Deleveraging (ADL) //

enum DeleverageType {
  ExitFundClosure,
  InsuranceFundClosure,
  WalletExitAcquisition,
  WalletInMaintenanceAcquisition
}

// Liquidations //

enum LiquidationType {
  WalletExited,
  WalletInMaintenance,
  WalletInMaintenanceDuringSystemRecovery
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
  // Good until crossing (post-only)
  gtx,
  // Immediate or cancel
  ioc,
  // Fill or kill
  fok
}

enum OrderTriggerType {
  // Not a triggered order
  None,
  // Last trade price
  Last,
  // Index price
  Index
}

enum OrderType {
  Market,
  Limit,
  StopLossMarket,
  StopLossLimit,
  TakeProfitMarket,
  TakeProfitLimit,
  TrailingStop
}
