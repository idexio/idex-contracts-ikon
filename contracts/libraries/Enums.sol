// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

/**
 * @notice Enums definitions
 */

// Automatic Deleveraging (ADL) //

enum DeleverageType {
  ExitAcquisition,
  ExitFundClosure,
  InMaintenanceAcquisition,
  InsuranceFundClosure
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
