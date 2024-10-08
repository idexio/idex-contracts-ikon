// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

/**
 * @notice Enums definitions
 */

// Automatic Deleveraging (ADL) //

enum DeleverageType {
  ExitFundClosure,
  InsuranceFundClosure,
  // The following two values are unused but included for completeness
  WalletExitAcquisition,
  WalletInMaintenanceAcquisition
}

enum WalletExitAcquisitionDeleveragePriceStrategy {
  None,
  BankruptcyPrice,
  ExitPrice
}

// Liquidations //

enum LiquidationType {
  WalletExit,
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
  // Good until canceled
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
