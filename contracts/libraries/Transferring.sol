// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Exiting } from "./Exiting.sol";
import { Funding } from "./Funding.sol";
import { Hashing } from "./Hashing.sol";
import { MutatingMargin } from "./MutatingMargin.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { Validations } from "./Validations.sol";
import { FundingMultiplierQuartet, IndexPrice, Market, MarketOverrides, Transfer } from "./Structs.sol";

library Transferring {
  using BalanceTracking for BalanceTracking.Storage;

  struct Arguments {
    // External arguments
    Transfer transfer;
    IndexPrice[] indexPrices;
    // Exchange state
    address exitFundWallet;
    address insuranceFundWallet;
    address feeWallet;
    address[] indexPriceCollectionServiceWallets;
  }

  // solhint-disable-next-line func-name-mixedcase
  function transfer_delegatecall(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(bytes32 => bool) storage completedTransferHashes,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => Exiting.WalletExit) storage walletExits
  ) public returns (int64 newSourceWalletExchangeBalance) {
    require(!Exiting.isWalletExitFinalized(arguments.transfer.sourceWallet, walletExits), "Wallet exited");

    require(arguments.transfer.sourceWallet != arguments.exitFundWallet, "Cannot transfer from EF");
    require(arguments.transfer.sourceWallet != arguments.insuranceFundWallet, "Cannot transfer from IF");

    require(arguments.transfer.destinationWallet != address(0x0), "Invalid destination wallet");
    require(arguments.transfer.destinationWallet != arguments.exitFundWallet, "Cannot transfer to EF");

    require(
      Validations.isFeeQuantityValid(arguments.transfer.gasFee, arguments.transfer.grossQuantity),
      "Excessive withdrawal fee"
    );
    bytes32 transferHash = _validateTransferSignature(arguments.transfer);
    require(!completedTransferHashes[transferHash], "Hash already transferred");

    Funding.updateWalletFunding(
      arguments.transfer.sourceWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFunding(
      arguments.transfer.destinationWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    // Update wallet balances
    newSourceWalletExchangeBalance = balanceTracking.updateForTransfer(arguments.transfer, arguments.feeWallet);

    // Wallet must still maintain initial margin requirement after withdrawal
    MutatingMargin.loadAndValidateTotalAccountValueAndInitialMarginRequirementAndUpdateLastIndexPrice(
      NonMutatingMargin.LoadArguments(
        arguments.transfer.sourceWallet,
        arguments.indexPrices,
        arguments.indexPriceCollectionServiceWallets
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    // Replay prevention
    completedTransferHashes[transferHash] = true;
  }

  function _validateTransferSignature(Transfer memory transfer) private pure returns (bytes32) {
    bytes32 transferHash = Hashing.getTransferHash(transfer);

    require(
      Hashing.isSignatureValid(transferHash, transfer.walletSignature, transfer.sourceWallet),
      "Invalid wallet signature"
    );

    return transferHash;
  }
}
