// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { AssetUnitConversions } from "./AssetUnitConversions.sol";
import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { ExitFund } from "./ExitFund.sol";
import { Hashing } from "./Hashing.sol";
import { ICustodian } from "./Interfaces.sol";
import { Funding } from "./Funding.sol";
import { Margin } from "./Margin.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { Validations } from "./Validations.sol";
import { Balance, FundingMultiplierQuartet, Market, IndexPrice, Withdrawal } from "./Structs.sol";

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

  function withdraw(
    WithdrawArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(bytes32 => bool) storage completedWithdrawalHashes,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (int64 newExchangeBalance) {
    // Validations
    if (arguments.withdrawal.wallet == arguments.exitFundWallet) {
      require(
        arguments.exitFundPositionOpenedAtBlockNumber == 0 ||
          arguments.exitFundPositionOpenedAtBlockNumber + Constants.MAX_CHAIN_PROPAGATION_PERIOD_IN_BLOCKS >=
          block.number,
        "EF position opened too recently"
      );
    }
    require(
      Validations.isFeeQuantityValid(arguments.withdrawal.gasFee, arguments.withdrawal.grossQuantity),
      "Excessive withdrawal fee"
    );
    bytes32 withdrawalHash = _validateWithdrawalSignature(arguments.withdrawal);
    require(!completedWithdrawalHashes[withdrawalHash], "Hash already withdrawn");

    Funding.updateWalletFundingInternal(
      arguments.withdrawal.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    // Update wallet balances
    newExchangeBalance = balanceTracking.updateForWithdrawal(
      arguments.withdrawal,
      Constants.QUOTE_ASSET_SYMBOL,
      arguments.feeWallet
    );

    require(
      Margin.isInitialMarginRequirementMetAndUpdateLastIndexPrice(
        Margin.LoadArguments(
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

  function withdrawExit(
    Withdrawing.WithdrawExitArguments memory arguments,
    uint256 exitFundPositionOpenedAtBlockNumber,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint256, uint64) {
    Funding.updateWalletFundingInternal(
      arguments.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    int64 quoteQuantity = _updatePositionsForExit(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    Balance storage balance = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );
    quoteQuantity += balance.balance;
    balance.balance = 0;

    require(quoteQuantity >= 0, "Negative quote after exit");

    arguments.custodian.withdraw(
      arguments.wallet,
      arguments.quoteAssetAddress,
      AssetUnitConversions.pipsToAssetUnits(uint64(quoteQuantity), Constants.QUOTE_ASSET_DECIMALS)
    );

    return (
      ExitFund.getExitFundBalanceOpenedAtBlockNumber(
        arguments.exitFundWallet,
        exitFundPositionOpenedAtBlockNumber,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet
      ),
      uint64(quoteQuantity)
    );
  }

  function _updatePositionsForExit(
    WithdrawExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (int64 quoteQuantity) {
    int64 totalAccountValue = Margin.loadTotalWalletExitAccountValue(
      Margin.LoadArguments(arguments.wallet, new IndexPrice[](0), arguments.indexPriceCollectionServiceWallets),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      // Sum quote quantites needed to close each wallet position
      quoteQuantity += balanceTracking.updateForExit(
        arguments.exitFundWallet,
        market,
        market.loadFeedPrice(),
        totalAccountValue,
        arguments.wallet,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    }

    // Total quote out from Exit Fund wallet calculated in loop
    Balance storage balance = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.exitFundWallet,
      Constants.QUOTE_ASSET_SYMBOL
    );
    balance.balance -= quoteQuantity;
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
