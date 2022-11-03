// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { ExitFund } from './ExitFund.sol';
import { ICustodian } from './Interfaces.sol';
import { Funding } from './Funding.sol';
import { Liquidation } from './Liquidation.sol';
import { Margin } from './Margin.sol';
import { MarketHelper } from './MarketHelper.sol';
import { Math } from './Math.sol';
import { Validations } from './Validations.sol';
import { Balance, FundingMultiplierQuartet, Market, OraclePrice, Withdrawal } from './Structs.sol';

library Withdrawing {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;

  struct WithdrawArguments {
    // External arguments
    Withdrawal withdrawal;
    OraclePrice[] oraclePrices;
    // Exchange state
    address quoteAssetAddress;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
    ICustodian custodian;
    uint256 exitFundPositionOpenedAtBlockNumber;
    address exitFundWallet;
    address feeWallet;
    address oracleWallet;
  }

  struct WithdrawExitArguments {
    // External arguments
    address wallet;
    // Exchange state
    ICustodian custodian;
    address exitFundWallet;
    address oracleWallet;
    address quoteAssetAddress;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
  }

  function withdraw(
    WithdrawArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(bytes32 => bool) storage completedWithdrawalHashes,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (int64 newExchangeBalanceInPips) {
    // Validations
    if (arguments.withdrawal.wallet == arguments.exitFundWallet) {
      require(
        arguments.exitFundPositionOpenedAtBlockNumber == 0 ||
          arguments.exitFundPositionOpenedAtBlockNumber +
            Constants.maxChainPropagationPeriodInBlocks >=
          block.number,
        'EF position opened too recently'
      );
    }
    require(
      Validations.isFeeQuantityValid(
        arguments.withdrawal.gasFeeInPips,
        arguments.withdrawal.grossQuantityInPips,
        Constants.maxFeeBasisPoints
      ),
      'Excessive withdrawal fee'
    );
    bytes32 withdrawalHash = Validations.validateWithdrawalSignature(
      arguments.withdrawal
    );
    require(
      !completedWithdrawalHashes[withdrawalHash],
      'Hash already withdrawn'
    );

    Funding.updateWalletFundingInternal(
      arguments.withdrawal.wallet,
      arguments.quoteAssetSymbol,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    // Update wallet balances
    newExchangeBalanceInPips = balanceTracking.updateForWithdrawal(
      arguments.withdrawal,
      arguments.quoteAssetSymbol,
      arguments.feeWallet
    );

    require(
      Margin.isInitialMarginRequirementMetAndUpdateLastOraclePrice(
        Margin.LoadArguments(
          arguments.withdrawal.wallet,
          arguments.oraclePrices,
          arguments.oracleWallet,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      ),
      'Initial margin requirement not met for buy wallet'
    );

    // Transfer funds from Custodian to wallet
    uint256 netAssetQuantityInAssetUnits = AssetUnitConversions
      .pipsToAssetUnits(
        arguments.withdrawal.grossQuantityInPips -
          arguments.withdrawal.gasFeeInPips,
        arguments.quoteAssetDecimals
      );
    arguments.custodian.withdraw(
      arguments.withdrawal.wallet,
      arguments.quoteAssetAddress,
      netAssetQuantityInAssetUnits
    );

    // Replay prevention
    completedWithdrawalHashes[withdrawalHash] = true;
  }

  function withdrawExit(
    Withdrawing.WithdrawExitArguments memory arguments,
    uint256 exitFundPositionOpenedAtBlockNumber,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint256, uint64) {
    Funding.updateWalletFundingInternal(
      arguments.wallet,
      arguments.quoteAssetSymbol,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    uint64 quoteQuantityInPips = withdrawExit(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    return (
      ExitFund.getExitFundBalanceOpenedAtBlockNumber(
        arguments.exitFundWallet,
        exitFundPositionOpenedAtBlockNumber,
        arguments.quoteAssetSymbol,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet
      ),
      quoteQuantityInPips
    );
  }

  function withdrawExit(
    WithdrawExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (uint64) {
    int64 quoteQuantityInPips = updatePositionsForExit(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
      arguments.wallet,
      arguments.quoteAssetSymbol
    );
    quoteQuantityInPips += balance.balanceInPips;
    balance.balanceInPips = 0;

    require(quoteQuantityInPips > 0, 'Negative quote after exit');

    arguments.custodian.withdraw(
      arguments.wallet,
      arguments.quoteAssetAddress,
      AssetUnitConversions.pipsToAssetUnits(
        uint64(quoteQuantityInPips),
        arguments.quoteAssetDecimals
      )
    );

    return uint64(quoteQuantityInPips);
  }

  function updatePositionsForExit(
    WithdrawExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (int64 quoteQuantityInPips) {
    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = loadTotalAccountValueAndMarginRequirement(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );

    string[]
      memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
        arguments.wallet
      ];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      quoteQuantityInPips += balanceTracking.updateForExit(
        arguments.exitFundWallet,
        market,
        market.loadFeedPriceInPips(),
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips,
        arguments.wallet,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    }

    // Quote out from exit fund wallet
    Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
      arguments.exitFundWallet,
      arguments.quoteAssetSymbol
    );
    balance.balanceInPips -= quoteQuantityInPips;
  }

  function loadTotalAccountValueAndMarginRequirement(
    WithdrawExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (int64, uint64) {
    int64 totalAccountValueInPips = Margin.loadTotalWalletExitAccountValue(
      Margin.LoadArguments(
        arguments.wallet,
        new OraclePrice[](0),
        arguments.oracleWallet,
        arguments.quoteAssetDecimals,
        arguments.quoteAssetSymbol
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    uint64 totalMaintenanceMarginRequirementInPips = Margin
      .loadTotalExitMaintenanceMarginRequirement(
        Margin.LoadArguments(
          arguments.wallet,
          new OraclePrice[](0),
          arguments.oracleWallet,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );

    return (totalAccountValueInPips, totalMaintenanceMarginRequirementInPips);
  }
}
