// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { AssetUnitConversions } from "./AssetUnitConversions.sol";
import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { ExitFund } from "./ExitFund.sol";
import { Hashing } from "./Hashing.sol";
import { ICustodian } from "./Interfaces.sol";
import { Funding } from "./Funding.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { MutatingMargin } from "./MutatingMargin.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { OnChainPriceFeedMargin } from "./OnChainPriceFeedMargin.sol";
import { Validations } from "./Validations.sol";
import { Balance, FundingMultiplierQuartet, IndexPrice, Market, MarketOverrides, Withdrawal } from "./Structs.sol";

library Withdrawing {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;

  struct WithdrawArguments {
    // External arguments
    Withdrawal withdrawal;
    IndexPrice[] indexPrices;
    // Exchange state
    address quoteAssetAddress;
    ICustodian custodian;
    uint256 exitFundPositionOpenedAtBlockNumber;
    address exitFundWallet;
    address feeWallet;
    address[] indexPriceCollectionServiceWallets;
  }

  struct WithdrawExitArguments {
    // External arguments
    address wallet;
    // Exchange state
    ICustodian custodian;
    address exitFundWallet;
    address[] indexPriceCollectionServiceWallets;
    address quoteAssetAddress;
  }

  // solhint-disable-next-line func-name-mixedcase
  function withdraw_delegatecall(
    WithdrawArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(bytes32 => bool) storage completedWithdrawalHashes,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (int64 newExchangeBalance) {
    // Validations
    if (arguments.withdrawal.wallet == arguments.exitFundWallet) {
      require(
        arguments.exitFundPositionOpenedAtBlockNumber == 0 ||
          block.number >= arguments.exitFundPositionOpenedAtBlockNumber + Constants.EXIT_FUND_WITHDRAW_DELAY_IN_BLOCKS,
        "EF position opened too recently"
      );
    }
    require(
      Validations.isFeeQuantityValid(arguments.withdrawal.gasFee, arguments.withdrawal.grossQuantity),
      "Excessive withdrawal fee"
    );
    bytes32 withdrawalHash = _validateWithdrawalSignature(arguments.withdrawal);
    require(!completedWithdrawalHashes[withdrawalHash], "Hash already withdrawn");

    Funding.updateWalletFunding(
      arguments.withdrawal.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    // Update wallet balances
    newExchangeBalance = balanceTracking.updateForWithdrawal(arguments.withdrawal, arguments.feeWallet);

    // Wallet must still maintain initial margin requirement after withdrawal
    require(
      MutatingMargin.isInitialMarginRequirementMetAndUpdateLastIndexPrice(
        NonMutatingMargin.LoadArguments(
          arguments.withdrawal.wallet,
          arguments.indexPrices,
          arguments.indexPriceCollectionServiceWallets
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      ),
      "Initial margin requirement not met for buy wallet"
    );

    // Transfer funds from Custodian to wallet
    uint256 netAssetQuantityInAssetUnits = AssetUnitConversions.pipsToAssetUnits(
      arguments.withdrawal.grossQuantity - arguments.withdrawal.gasFee,
      Constants.QUOTE_ASSET_DECIMALS
    );
    arguments.custodian.withdraw(
      arguments.withdrawal.wallet,
      arguments.quoteAssetAddress,
      netAssetQuantityInAssetUnits
    );

    // Replay prevention
    completedWithdrawalHashes[withdrawalHash] = true;
  }

  // solhint-disable-next-line func-name-mixedcase
  function withdrawExit_delegatecall(
    Withdrawing.WithdrawExitArguments memory arguments,
    uint256 exitFundPositionOpenedAtBlockNumber,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint256, uint64) {
    Funding.updateWalletFunding(
      arguments.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    // The wallet's change in quote quantity is inverse to the EF's change in quote quantity
    int64 walletQuoteQuantityChange = -1 *
      _updatePositionsForExit(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );

    Balance storage balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );
    // Add any existing quote balance to the quote change from positions to obtain total amount for withdrawal
    walletQuoteQuantityChange += balanceStruct.balance;
    // Zero out quote balance
    balanceStruct.balance = 0;

    require(walletQuoteQuantityChange >= 0, "Negative quote after exit");

    arguments.custodian.withdraw(
      arguments.wallet,
      arguments.quoteAssetAddress,
      AssetUnitConversions.pipsToAssetUnits(uint64(walletQuoteQuantityChange), Constants.QUOTE_ASSET_DECIMALS)
    );

    return (
      ExitFund.getExitFundBalanceOpenedAtBlockNumber(
        arguments.exitFundWallet,
        exitFundPositionOpenedAtBlockNumber,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet
      ),
      uint64(walletQuoteQuantityChange)
    );
  }

  function _updateBalancesForPositionExit(
    WithdrawExitArguments memory arguments,
    string memory baseAssetSymbol,
    uint64 maintenanceMarginFraction,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (int64 exitFundQuoteQuantityChange) {
    return
      balanceTracking.updateForExit(
        BalanceTracking.UpdateForExitArguments(
          arguments.exitFundWallet,
          marketsByBaseAssetSymbol[baseAssetSymbol],
          maintenanceMarginFraction,
          totalAccountValue,
          totalMaintenanceMarginRequirement,
          arguments.wallet
        ),
        baseAssetSymbolsWithOpenPositionsByWallet,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );
  }

  function _updatePositionsForExit(
    WithdrawExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (int64 exitFundQuoteQuantityChange) {
    (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = OnChainPriceFeedMargin
      .loadTotalAccountValueAndMaintenanceMarginRequirement(
        arguments.wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      // Sum EF quote quantity change needed to close each wallet position
      exitFundQuoteQuantityChange += _updateBalancesForPositionExit(
        arguments,
        baseAssetSymbols[i],
        marketsByBaseAssetSymbol[baseAssetSymbols[i]]
          .loadMarketWithOverridesForWallet(arguments.wallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        totalAccountValue,
        totalMaintenanceMarginRequirement,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    }

    // Update EF quote balance with total quote change calculated above in loop
    Balance storage balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.exitFundWallet,
      Constants.QUOTE_ASSET_SYMBOL
    );
    balanceStruct.balance += exitFundQuoteQuantityChange;
  }

  function _validateWithdrawalSignature(Withdrawal memory withdrawal) private pure returns (bytes32) {
    bytes32 withdrawalHash = Hashing.getWithdrawalHash(withdrawal);

    require(
      Hashing.isSignatureValid(withdrawalHash, withdrawal.walletSignature, withdrawal.wallet),
      "Invalid wallet signature"
    );

    return withdrawalHash;
  }
}
