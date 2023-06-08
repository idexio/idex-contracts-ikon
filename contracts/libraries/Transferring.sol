// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Funding } from "./Funding.sol";
import { Hashing } from "./Hashing.sol";
import { IndexPriceMargin } from "./IndexPriceMargin.sol";
import { Validations } from "./Validations.sol";
import { WalletExits } from "./WalletExits.sol";
import { FundingMultiplierQuartet, Market, MarketOverrides, Transfer, WalletExit } from "./Structs.sol";

library Transferring {
  using BalanceTracking for BalanceTracking.Storage;

  struct Arguments {
    // External arguments
    Transfer transfer;
    // Exchange state
    bytes32 domainSeparator;
    address exitFundWallet;
    address insuranceFundWallet;
    address feeWallet;
  }

  /**
   * @notice Emitted when the Dispatcher Wallet submits a transfer with `transfer`
   */
  event Transferred(
    address sourceWallet,
    address destinationWallet,
    uint64 quantity,
    int64 newSourceWalletExchangeBalance
  );

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
    mapping(address => WalletExit) storage walletExits
  ) public {
    require(!WalletExits.isWalletExitFinalized(arguments.transfer.sourceWallet, walletExits), "Source wallet exited");
    require(
      !WalletExits.isWalletExitFinalized(arguments.transfer.destinationWallet, walletExits),
      "Destination wallet exited"
    );
    require(arguments.transfer.sourceWallet != arguments.transfer.destinationWallet, "Cannot self-transfer");

    require(arguments.transfer.sourceWallet != arguments.exitFundWallet, "Cannot transfer from EF");
    require(arguments.transfer.sourceWallet != arguments.insuranceFundWallet, "Cannot transfer from IF");

    require(arguments.transfer.destinationWallet != address(0x0), "Invalid destination wallet");
    require(arguments.transfer.destinationWallet != arguments.exitFundWallet, "Cannot transfer to EF");

    require(
      Validations.isFeeQuantityValid(arguments.transfer.gasFee, arguments.transfer.grossQuantity),
      "Excessive transfer fee"
    );
    bytes32 transferHash = _validateTransferSignature(arguments);
    require(!completedTransferHashes[transferHash], "Duplicate transfer");

    Funding.applyOutstandingWalletFunding(
      arguments.transfer.sourceWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.applyOutstandingWalletFunding(
      arguments.transfer.destinationWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    // Update wallet balances
    int64 newSourceWalletExchangeBalance = balanceTracking.updateForTransfer(arguments.transfer, arguments.feeWallet);

    // Wallet must still maintain initial margin requirement after withdrawal
    IndexPriceMargin.validateInitialMarginRequirement(
      arguments.transfer.sourceWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    // Replay prevention
    completedTransferHashes[transferHash] = true;

    emit Transferred(
      arguments.transfer.sourceWallet,
      arguments.transfer.destinationWallet,
      arguments.transfer.grossQuantity,
      newSourceWalletExchangeBalance
    );
  }

  function _validateTransferSignature(Arguments memory arguments) private pure returns (bytes32) {
    bytes32 transferHash = Hashing.getTransferHash(arguments.transfer);

    require(
      Hashing.isSignatureValid(
        arguments.domainSeparator,
        transferHash,
        arguments.transfer.walletSignature,
        arguments.transfer.sourceWallet
      ),
      "Invalid wallet signature"
    );

    return transferHash;
  }
}
