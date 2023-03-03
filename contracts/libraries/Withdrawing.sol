// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AssetUnitConversions } from "./AssetUnitConversions.sol";
import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { ExitFund } from "./ExitFund.sol";
import { Hashing } from "./Hashing.sol";
import { Funding } from "./Funding.sol";
import { IndexPriceMargin } from "./IndexPriceMargin.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { OraclePriceMargin } from "./OraclePriceMargin.sol";
import { String } from "./String.sol";
import { Validations } from "./Validations.sol";
import { WalletExits } from "./WalletExits.sol";
import { IBridgeAdapter, ICustodian } from "./Interfaces.sol";
import { Balance, FundingMultiplierQuartet, Market, MarketOverrides, Withdrawal } from "./Structs.sol";

library Withdrawing {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;

  struct WithdrawArguments {
    // External arguments
    Withdrawal withdrawal;
    // Exchange state
    address quoteTokenAddress;
    ICustodian custodian;
    uint256 exitFundPositionOpenedAtBlockNumber;
    address exitFundWallet;
    address feeWallet;
  }

  struct WithdrawExitArguments {
    // External arguments
    address wallet;
    // Exchange state
    ICustodian custodian;
    address exitFundWallet;
    address quoteTokenAddress;
  }

  // solhint-disable-next-line func-name-mixedcase
  function exitWallet_delegatecall(
    uint256 chainPropagationPeriodInBlocks,
    address exitFundWallet,
    address insuranceFundWallet,
    address wallet,
    mapping(address => WalletExits.WalletExit) storage walletExits
  ) external returns (uint256 blockThreshold) {
    require(!walletExits[wallet].exists, "Wallet already exited");
    require(wallet != insuranceFundWallet, "Cannot exit IF");
    require(wallet != exitFundWallet, "Cannot exit EF");

    blockThreshold = block.number + chainPropagationPeriodInBlocks;
    walletExits[wallet] = WalletExits.WalletExit(true, blockThreshold);
  }

  // solhint-disable-next-line func-name-mixedcase
  function skim_delegatecall(address tokenAddress, address feeWallet) public {
    require(Address.isContract(tokenAddress), "Invalid token address");

    uint256 balance = IERC20(tokenAddress).balanceOf(address(this));

    // Ignore the return value of transfer
    IERC20(tokenAddress).transfer(feeWallet, balance);
  }

  // solhint-disable-next-line func-name-mixedcase
  function withdraw_delegatecall(
    WithdrawArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(bytes32 => bool) storage completedWithdrawalHashes,
    IBridgeAdapter[] storage bridgeAdapters,
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
    require(!completedWithdrawalHashes[withdrawalHash], "Duplicate withdrawal");

    Funding.applyOutstandingWalletFunding(
      arguments.withdrawal.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    // Update wallet balances
    newExchangeBalance = balanceTracking.updateForWithdrawal(arguments.withdrawal, arguments.feeWallet);

    // EF has no margin requirements but may not withdraw quote balance below zero
    if (arguments.withdrawal.wallet == arguments.exitFundWallet) {
      require(newExchangeBalance >= 0, "EF may not withdraw to a negative balance");
    } else {
      // Wallet must still maintain initial margin requirement after withdrawal
      IndexPriceMargin.validateInitialMarginRequirement(
        arguments.withdrawal.wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    }

    _transferWithdrawnQuoteAsset(arguments, bridgeAdapters);

    // Replay prevention
    completedWithdrawalHashes[withdrawalHash] = true;
  }

  // solhint-disable-next-line func-name-mixedcase
  function withdrawExit_delegatecall(
    WithdrawExitArguments memory arguments,
    uint256 exitFundPositionOpenedAtBlockNumber,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => WalletExits.WalletExit) storage walletExits
  ) public returns (uint256, uint64) {
    Funding.applyOutstandingWalletFunding(
      arguments.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    int64 walletQuoteQuantityToWithdraw;

    if (arguments.wallet == arguments.exitFundWallet) {
      // Do not require prior exit for EF as it is already subject to a specific EF withdrawal delay
      _validateExitFundWithdrawDelayElapsed(exitFundPositionOpenedAtBlockNumber);

      // The EF wallet can withdraw its positive quote balance
      walletQuoteQuantityToWithdraw = balanceTracking.updateExitFundWalletForExit(arguments.exitFundWallet);
    } else {
      require(WalletExits.isWalletExitFinalized(arguments.wallet, walletExits), "Wallet exit not finalized");

      walletQuoteQuantityToWithdraw = _updatePositionsForWalletExit(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );

      // Rounding errors can lead to a slightly negative result instead of zero - within the tolerance, coerce to zero
      // in these cases to allow wallet positions to be closed out
      if (
        walletQuoteQuantityToWithdraw < 0 &&
        Math.abs(walletQuoteQuantityToWithdraw) <= Constants.MINIMUM_QUOTE_QUANTITY_VALIDATION_THRESHOLD
      ) {
        walletQuoteQuantityToWithdraw = 0;
      }
    }

    // The available quote for exit can validly be negative for the EF wallet. For all other wallets, the exit quote
    // calculations are designed such that the result quantity to withdraw is never negative; however we still perform
    // this check in case of unforeseen bugs or rounding errors. In either case we should revert on negative
    // A zero available quantity would not transfer out any quote but would still close all positions and quote
    // balance, so we do not revert on zero
    require(walletQuoteQuantityToWithdraw >= 0, "Negative quote after exit");

    arguments.custodian.withdraw(
      arguments.wallet,
      arguments.quoteTokenAddress,
      AssetUnitConversions.pipsToAssetUnits(uint64(walletQuoteQuantityToWithdraw), Constants.QUOTE_TOKEN_DECIMALS)
    );

    return (
      ExitFund.getExitFundBalanceOpenedAtBlockNumber(
        exitFundPositionOpenedAtBlockNumber,
        arguments.exitFundWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet
      ),
      // Quote quantity will never be negative per design of exit quote calculations
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
    // Outstanding funding payments already applied in withdrawExit_delegatecall
    (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = OraclePriceMargin
      .loadTotalAccountValueAndMaintenanceMarginRequirement(
        0,
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
        BalanceTracking.UpdatePositionForExitArguments(
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
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol
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

  function _transferWithdrawnQuoteAsset(
    WithdrawArguments memory arguments,
    IBridgeAdapter[] storage bridgeAdapters
  ) private {
    // Transfer funds from Custodian to wallet
    uint256 netAssetQuantityInAssetUnits = AssetUnitConversions.pipsToAssetUnits(
      arguments.withdrawal.grossQuantity - arguments.withdrawal.gasFee,
      Constants.QUOTE_TOKEN_DECIMALS
    );
    if (arguments.withdrawal.bridgeAdapter == address(0x0)) {
      arguments.custodian.withdraw(
        arguments.withdrawal.wallet,
        arguments.quoteTokenAddress,
        netAssetQuantityInAssetUnits
      );
    } else {
      bool bridgeAdapterIsWhitelisted = false;
      for (uint8 i = 0; i < bridgeAdapters.length; i++) {
        if (arguments.withdrawal.bridgeAdapter == address(bridgeAdapters[i])) {
          bridgeAdapterIsWhitelisted = true;
          break;
        }
      }
      require(bridgeAdapterIsWhitelisted, "Invalid bridge adapter");

      arguments.custodian.withdraw(
        arguments.withdrawal.bridgeAdapter,
        arguments.quoteTokenAddress,
        netAssetQuantityInAssetUnits
      );
      IBridgeAdapter(arguments.withdrawal.bridgeAdapter).withdrawQuoteAsset(
        arguments.withdrawal.wallet,
        netAssetQuantityInAssetUnits,
        arguments.withdrawal.bridgeAdapterPayload
      );
    }
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
