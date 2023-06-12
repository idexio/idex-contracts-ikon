// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IExchange } from "./libraries/Interfaces.sol";
import { Balance, Market, NonceInvalidation, WalletExit } from "./libraries/Structs.sol";

interface IExchangeExtended is IExchange {
  function loadLastNonceInvalidationForWallet(
    address wallet
  ) external view returns (NonceInvalidation memory nonceInvalidation);

  function walletExits(address wallet) external view returns (WalletExit memory walletExit);
}

contract ExchangeWalletStateAggregator {
  struct WalletState {
    Balance[] balances;
    WalletExit walletExit;
    NonceInvalidation nonceInvalidation;
  }

  IExchangeExtended public immutable exchange;

  constructor(address exchange_) {
    require(Address.isContract(exchange_), "Invalid Exchange address");

    exchange = IExchangeExtended(exchange_);
  }

  function loadWalletStates(address[] memory wallets) public view returns (WalletState[] memory walletStates) {
    walletStates = new WalletState[](wallets.length);

    uint256 marketsLength = exchange.loadMarketsLength();
    string[] memory baseAssetSymbols = new string[](marketsLength);
    for (uint8 i = 0; i < marketsLength; ++i) {
      baseAssetSymbols[i] = exchange.loadMarket(i).baseAssetSymbol;
    }

    for (uint256 i = 0; i < wallets.length; ++i) {
      walletStates[i].nonceInvalidation = exchange.loadLastNonceInvalidationForWallet(wallets[i]);
      walletStates[i].walletExit = exchange.walletExits(wallets[i]);

      walletStates[i].balances = new Balance[](marketsLength);
      for (uint8 j = 0; j < marketsLength; ++j) {
        walletStates[i].balances[j] = exchange.loadBalanceStructBySymbol(wallets[i], baseAssetSymbols[j]);
      }
    }
  }
}
