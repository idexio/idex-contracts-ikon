// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { Constants } from "../libraries/Constants.sol";
import { Hashing } from "../libraries/Hashing.sol";
import { IIndexPriceAdapter } from "../libraries/Interfaces.sol";
import { IndexPrice } from "../libraries/Structs.sol";
import { Owned } from "../Owned.sol";
import { String } from "../libraries/String.sol";

contract IDEXIndexPriceAdapter is IIndexPriceAdapter, Owned {
  bytes32 public constant EIP_712_TYPE_HASH_INDEX_PRICE =
    keccak256("IndexPrice(string baseAssetSymbol,string quoteAssetSymbol,uint64 timestampInMs,string price)");

  // Address of Exchange contract
  address public exchange;

  // EIP-712 domain separator hash for Exchange
  bytes32 public exchangeDomainSeparator;

  // IPS wallet addresses whitelisted to sign index price payloads
  address[] public indexPriceServiceWallets;

  // Mapping of base asset symbol => index price struct
  mapping(string => IndexPrice) public latestIndexPriceByBaseAssetSymbol;

  modifier onlyExchange() {
    require(msg.sender == exchange, "Caller must be Exchange contract");
    _;
  }

  /**
   * @notice Instantiate a new `IDEXIndexPriceAdapter` contract
   *
   * @param indexPriceServiceWallets_ Addresses of IPS wallets whitelisted to sign index prices
   */
  constructor(address[] memory indexPriceServiceWallets_) {
    for (uint8 i = 0; i < indexPriceServiceWallets_.length; i++) {
      require(indexPriceServiceWallets_[i] != address(0x0), "Invalid IPS wallet");
    }
    indexPriceServiceWallets = indexPriceServiceWallets_;
  }

  /**
   * @notice Sets Exchange contract address used for EIP-712 domain and access control. This value is immutable once
   * set and cannot be changed again
   *
   * @param exchange_ The address of the new whitelisted Exchange contract
   */
  function setExchange(address exchange_) public onlyOwner {
    require(exchange == address(0x0), "Exchange contract can only be set once");
    require(Address.isContract(exchange_), "Invalid Exchange contract address");

    exchange = exchange_;
    exchangeDomainSeparator = keccak256(
      abi.encode(
        Constants.EIP_712_TYPE_HASH_DOMAIN,
        keccak256(bytes(Constants.EIP_712_DOMAIN_NAME)),
        keccak256(bytes(Constants.EIP_712_DOMAIN_VERSION)),
        block.chainid,
        exchange_
      )
    );
  }

  /**
   * @notice Return latest price for base asset symbol in quote asset terms. Reverts if no price is available
   */
  function loadPriceForBaseAssetSymbol(string memory baseAssetSymbol) public view returns (uint64 price) {
    IndexPrice memory indexPrice = latestIndexPriceByBaseAssetSymbol[baseAssetSymbol];
    require(indexPrice.price > 0, "Missing price");

    return indexPrice.price;
  }

  /**
   * @notice Validate encoded payload and return decoded `IndexPrice` struct
   */
  function validateIndexPricePayload(bytes memory payload) public onlyExchange returns (IndexPrice memory) {
    (IndexPrice memory indexPrice, bytes memory signature) = abi.decode(payload, (IndexPrice, bytes));

    // Extract signer from signature
    address signer = Hashing.getSigner(
      exchangeDomainSeparator,
      keccak256(
        abi.encode(
          EIP_712_TYPE_HASH_INDEX_PRICE,
          keccak256(bytes(indexPrice.baseAssetSymbol)),
          keccak256(bytes(Constants.QUOTE_ASSET_SYMBOL)),
          indexPrice.timestampInMs,
          keccak256(bytes(String.pipsToDecimalString(indexPrice.price)))
        )
      ),
      signature
    );

    // Verify signer is whitelisted
    bool isSignatureValid = false;
    for (uint8 i = 0; i < indexPriceServiceWallets.length; i++) {
      isSignatureValid = isSignatureValid || signer == indexPriceServiceWallets[i];
    }
    require(isSignatureValid, "Invalid index price signature");

    if (latestIndexPriceByBaseAssetSymbol[indexPrice.baseAssetSymbol].timestampInMs < indexPrice.timestampInMs) {
      latestIndexPriceByBaseAssetSymbol[indexPrice.baseAssetSymbol] = indexPrice;
    }

    return indexPrice;
  }
}
