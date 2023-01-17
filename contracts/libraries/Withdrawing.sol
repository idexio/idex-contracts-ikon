// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { AssetUnitConversions } from "./AssetUnitConversions.sol";
import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { Exiting } from "./Exiting.sol";
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
  function exitWallet_delegatecall(
    uint256 chainPropagationPeriodInBlocks,
    address exitFundWallet,
    address insuranceFundWallet,
    address wallet,
    mapping(address => Exiting.WalletExit) storage walletExits
  ) external returns (uint256 blockThreshold) {
    require(!walletExits[wallet].exists, "Wallet already exited");
    require(wallet != insuranceFundWallet, "Cannot exit IF");
    require(wallet != exitFundWallet, "Cannot exit EF");

    blockThreshold = block.number + chainPropagationPeriodInBlocks;
    walletExits[wallet] = Exiting.WalletExit(true, blockThreshold);
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
    // Validate preconditions
    if (arguments.withdrawal.wallet == arguments.exitFundWallet) {
      _validateExitFundWithdrawDelayElapsed(arguments.exitFundPositionOpenedAtBlockNumber);
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

    // EF has no margin requirements but may only withdraw to zero
    if (arguments.withdrawal.wallet == arguments.exitFundWallet) {
      require(newExchangeBalance >= 0, "EF may only withdraw to zero");
    } else {
      // Wallet must still maintain initial margin requirement after withdrawal
      MutatingMargin.loadAndValidateTotalAccountValueAndInitialMarginRequirementAndUpdateLastIndexPrice(
        NonMutatingMargin.LoadArguments(
          arguments.withdrawal.wallet,
          arguments.indexPrices,
          arguments.indexPriceCollectionServiceWallets
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    }

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
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => Exiting.WalletExit) storage walletExits
  ) public returns (uint256, uint64) {
    // Do not require prior exit for EF as it is already subject to a specific withdrawal delay
    require(
      arguments.wallet == arguments.exitFundWallet || Exiting.isWalletExitFinalized(arguments.wallet, walletExits),
      "Wallet exit not finalized"
    );

    Funding.updateWalletFunding(
      arguments.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    int64 walletQuoteQuantityToWithdraw;

    if (arguments.wallet == arguments.exitFundWallet) {
      _validateExitFundWithdrawDelayElapsed(exitFundPositionOpenedAtBlockNumber);

      walletQuoteQuantityToWithdraw = balanceTracking.updateExitFundWalletForExit(arguments.exitFundWallet);
    } else {
      walletQuoteQuantityToWithdraw = _updatePositionsForWalletExit(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    }

    require(walletQuoteQuantityToWithdraw >= 0, "Negative quote after exit");

    arguments.custodian.withdraw(
      arguments.wallet,
      arguments.quoteAssetAddress,
      AssetUnitConversions.pipsToAssetUnits(uint64(walletQuoteQuantityToWithdraw), Constants.QUOTE_ASSET_DECIMALS)
    );

    return (
      ExitFund.getExitFundBalanceOpenedAtBlockNumber(
        arguments.exitFundWallet,
        exitFundPositionOpenedAtBlockNumber,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet
      ),
      uint64(walletQuoteQuantityToWithdraw)
    );
  }

  function _updatePositionsForWalletExit(
    WithdrawExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (int64 walletQuoteQuantityToWithdraw) {
    (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = OnChainPriceFeedMargin
      .loadTotalAccountValueAndMaintenanceMarginRequirement(
        arguments.wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );

    int64 exitFundQuoteQuantityChange;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      // Sum EF quote quantity change needed to close each wallet position
      exitFundQuoteQuantityChange += balanceTracking.updatePositionForExit(
        BalanceTracking.UpdateForExitArguments(
          arguments.exitFundWallet,
          marketsByBaseAssetSymbol[baseAssetSymbols[i]],
          marketsByBaseAssetSymbol[baseAssetSymbols[i]]
            .loadMarketWithOverridesForWallet(arguments.wallet, marketOverridesByBaseAssetSymbolAndWallet)
            .overridableFields
            .maintenanceMarginFraction,
          totalAccountValue,
          totalMaintenanceMarginRequirement,
          arguments.wallet
        ),
        baseAssetSymbolsWithOpenPositionsByWallet,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    }

    // Update EF quote balance with total quote change calculated above in loop
    Balance storage balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.exitFundWallet,
      Constants.QUOTE_ASSET_SYMBOL
    );
    balanceStruct.balance += exitFundQuoteQuantityChange;

    // Update exiting wallet's quote balance
    balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(arguments.wallet, Constants.QUOTE_ASSET_SYMBOL);
    // The wallet's change in quote quantity from position closure is inverse to that of the EF to acquire them.
    // Subtract the EF quote change from wallet's existing quote balance to obtain total quote available for withdrawal
    walletQuoteQuantityToWithdraw = balanceStruct.balance - exitFundQuoteQuantityChange;
    // Zero out quote balance
    balanceStruct.balance = 0;
  }

  function _validateExitFundWithdrawDelayElapsed(uint256 exitFundPositionOpenedAtBlockNumber) private view {
    require(
      block.number >= exitFundPositionOpenedAtBlockNumber + Constants.EXIT_FUND_WITHDRAW_DELAY_IN_BLOCKS,
      "EF position opened too recently"
    );
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
