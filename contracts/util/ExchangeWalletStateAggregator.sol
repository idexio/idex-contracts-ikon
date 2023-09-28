// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { Constants } from "../libraries/Constants.sol";
import { IExchange } from "../libraries/Interfaces.sol";
import { Balance, Market, NonceInvalidation, WalletExit } from "../libraries/Structs.sol";

interface IExchangeExtended is IExchange {
  function loadLastNonceInvalidationForWallet(
    address wallet
  ) external view returns (NonceInvalidation memory nonceInvalidation);

  function loadOutstandingWalletFunding(address wallet) external view returns (int64);

  function pendingDepositQuantityByWallet(address wallet) external view returns (uint64);

  function walletExits(address wallet) external view returns (WalletExit memory walletExit);
}

struct WalletState {
  Balance[] balances;
  uint64 pendingDepositQuantity;
  WalletExit walletExit;
  NonceInvalidation nonceInvalidation;
}

contract ExchangeWalletStateAggregator {
  IExchangeExtended public immutable exchange;

  constructor(address exchange_) {
    require(Address.isContract(exchange_), "Invalid Exchange address");

    exchange = IExchangeExtended(exchange_);
  }

  function loadWalletStates(address[] memory wallets) public view returns (WalletState[] memory walletStates) {
    walletStates = new WalletState[](wallets.length);

    // Construct an array of base asset symbols for all listed markets
    uint256 marketsLength = exchange.loadMarketsLength();
    string[] memory baseAssetSymbols = new string[](marketsLength);
    for (uint8 i = 0; i < marketsLength; ++i) {
      baseAssetSymbols[i] = exchange.loadMarket(i).baseAssetSymbol;
    }

    for (uint256 i = 0; i < wallets.length; ++i) {
      walletStates[i].pendingDepositQuantity = exchange.pendingDepositQuantityByWallet(wallets[i]);
      walletStates[i].nonceInvalidation = exchange.loadLastNonceInvalidationForWallet(wallets[i]);
      walletStates[i].walletExit = exchange.walletExits(wallets[i]);

      // The first element in the balances array is reserved for the quote asset
      walletStates[i].balances = new Balance[](marketsLength + 1);
      walletStates[i].balances[0] = exchange.loadBalanceStructBySymbol(wallets[i], Constants.QUOTE_ASSET_SYMBOL);
      walletStates[i].balances[0].balance += exchange.loadOutstandingWalletFunding(wallets[i]);
      for (uint8 j = 0; j < marketsLength; ++j) {
        walletStates[i].balances[j + 1] = exchange.loadBalanceStructBySymbol(wallets[i], baseAssetSymbols[j]);
      }
    }
  }
}
