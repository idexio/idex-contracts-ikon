import BigNumber from 'bignumber.js';
import { ethers } from 'ethers';
import {
  AcquisitionDeleverageArgumentsStruct,
  ClosureDeleverageArgumentsStruct,
  ExecuteTradeArgumentsStruct,
  IndexPricePayloadStruct,
  TradeStruct,
  OrderStruct,
  OverridableMarketFieldsStruct,
  PositionBelowMinimumLiquidationArgumentsStruct,
  PositionInDeactivatedMarketLiquidationArgumentsStruct,
  TransferStruct,
  WalletLiquidationArgumentsStruct,
  WithdrawalStruct,
} from '../typechain-types/contracts/Exchange.sol/Exchange_v4';

import * as contracts from './contracts';

export {
  AcquisitionDeleverageArgumentsStruct,
  ClosureDeleverageArgumentsStruct,
  ExecuteTradeArgumentsStruct,
  IndexPricePayloadStruct,
  TradeStruct,
  OrderStruct,
  OverridableMarketFieldsStruct,
  PositionBelowMinimumLiquidationArgumentsStruct,
  PositionInDeactivatedMarketLiquidationArgumentsStruct,
  TransferStruct,
  WalletLiquidationArgumentsStruct,
  WithdrawalStruct,
};

export { contracts };

export const fundingPeriodLengthInMs = 8 * 60 * 60 * 1000;

/** The fixed number of digits following the decimal in quantities expressed as pips */
export const pipsDecimals = 8;

export const signatureHashVersion = 105;

export enum OrderSelfTradePrevention {
  DecreaseAndCancel,
  CancelOldest,
  CancelNewest,
  CancelBoth,
}

export enum OrderSide {
  Buy,
  Sell,
}

export enum OrderTimeInForce {
  GTC,
  GTX,
  IOC,
  FOK,
}

export enum OrderType {
  Market,
  Limit,
  StopLossMarket,
  StopLossLimit,
  TakeProfitMarket,
  TakeProfitLimit,
  TrailingStop,
}

export enum OrderTriggerType {
  Last,
  Index,
}

export interface IndexPrice {
  baseAssetSymbol: string;
  timestampInMs: number;
  price: string; // Decimal string
  signature: string;
}

export interface Order {
  nonce: string;
  wallet: string;
  market: string;
  type: OrderType;
  side: OrderSide;
  quantity: string;
  price: string;
  triggerPrice?: string;
  triggerType?: OrderTriggerType;
  callbackRate?: string;
  conditionalOrderId?: string;
  isReduceOnly?: boolean;
  timeInForce?: OrderTimeInForce;
  selfTradePrevention?: OrderSelfTradePrevention;
  delegatedPublicKey?: string;
  clientOrderId?: string;
}

export interface DelegatedKeyAuthorization {
  nonce: string;
  delegatedPublicKey: string;
  signature: string;
}

export interface Trade {
  baseAssetSymbol: string;
  baseQuantity: string;
  quoteQuantity: string;
  makerFeeQuantity: string;
  takerFeeQuantity: string;
  price: string; // Decimal string
  makerSide: OrderSide;
}

export interface Transfer {
  nonce: string;
  sourceWallet: string;
  destinationWallet: string;
  quantity: string; // Decimal string
}

export interface Withdrawal {
  nonce: string;
  wallet: string;
  quantity: string; // Decimal string
  bridgeAdapter: string;
  bridgeAdapterPayload: string;
}

export const hardhatChainId = 31337;

export const compareMarketSymbols = (a: string, b: string): number =>
  Buffer.compare(
    ethers.utils.arrayify(ethers.utils.solidityKeccak256(['string'], [a])),
    ethers.utils.arrayify(ethers.utils.solidityKeccak256(['string'], [b])),
  );

export const decimalToAssetUnits = (
  decimal: string,
  decimals: number,
): string => pipsToAssetUnits(decimalToPips(decimal), decimals);

export const delegatedKeyAuthorizationMessage =
  "Hello from the IDEX team! Sign this message to prove you have control of this wallet. This won't cost you any gas fees.";

/**
 * Convert decimal quantity string to integer pips as expected by contract structs. Truncates
 * anything beyond 8 decimals
 */
export const decimalToPips = (decimal: string): string =>
  new BigNumber(decimal)
    .shiftedBy(8)
    .integerValue(BigNumber.ROUND_DOWN)
    .toFixed(0);

export const getDomainSeparator = (
  contractAddress: string,
  chainId: number,
) => {
  return {
    name: 'IDEX',
    version: `${signatureHashVersion}`,
    chainId,
    verifyingContract: contractAddress,
  };
};

export const getDelegatedKeyAuthorizationSignatureTypedData = (
  delegatedKeyAuthorization: Omit<DelegatedKeyAuthorization, 'signature'>,
  contractAddress: string,
  chainId = hardhatChainId,
): Parameters<ethers.providers.JsonRpcSigner['_signTypedData']> => {
  return [
    getDomainSeparator(contractAddress, chainId),
    {
      DelegatedKeyAuthorization: [
        { name: 'nonce', type: 'uint128' },
        { name: 'delegatedPublicKey', type: 'address' },
        { name: 'message', type: 'string' },
      ],
    },
    {
      nonce: uuidToUint8Array(delegatedKeyAuthorization.nonce),
      delegatedPublicKey: delegatedKeyAuthorization.delegatedPublicKey,
      message: delegatedKeyAuthorizationMessage,
    },
  ];
};

export const getIndexPriceSignatureTypedData = (
  indexPrice: Omit<IndexPrice, 'signature'>,
  quoteAssetSymbol: string,
  contractAddress: string,
  chainId = hardhatChainId,
): Parameters<ethers.providers.JsonRpcSigner['_signTypedData']> => {
  return [
    getDomainSeparator(contractAddress, chainId),
    {
      IndexPrice: [
        { name: 'baseAssetSymbol', type: 'string' },
        { name: 'quoteAssetSymbol', type: 'string' },
        { name: 'timestampInMs', type: 'uint64' },
        { name: 'price', type: 'string' },
      ],
    },
    {
      baseAssetSymbol: indexPrice.baseAssetSymbol,
      quoteAssetSymbol,
      timestampInMs: indexPrice.timestampInMs,
      price: indexPrice.price,
    },
  ];
};

export const getOrderSignatureTypedData = (
  order: Order,
  contractAddress: string,
  chainId = hardhatChainId,
): Parameters<ethers.providers.JsonRpcSigner['_signTypedData']> => {
  const emptyPipString = '0.00000000';

  return [
    getDomainSeparator(contractAddress, chainId),
    {
      Order: [
        { name: 'nonce', type: 'uint128' },
        { name: 'wallet', type: 'address' },
        { name: 'marketSymbol', type: 'string' },
        { name: 'orderType', type: 'uint8' },
        { name: 'orderSide', type: 'uint8' },
        { name: 'quantity', type: 'string' },
        { name: 'limitPrice', type: 'string' },
        { name: 'triggerPrice', type: 'string' },
        { name: 'triggerType', type: 'uint8' },
        { name: 'callbackRate', type: 'string' },
        { name: 'conditionalOrderId', type: 'uint128' },
        { name: 'isReduceOnly', type: 'bool' },
        { name: 'timeInForce', type: 'uint8' },
        { name: 'selfTradePrevention', type: 'uint8' },
        { name: 'delegatedPublicKey', type: 'address' },
        { name: 'clientOrderId', type: 'string' },
      ],
    },
    {
      nonce: uuidToUint8Array(order.nonce),
      wallet: order.wallet,
      marketSymbol: order.market,
      orderType: order.type,
      orderSide: order.side,
      quantity: order.quantity,
      limitPrice: order.price || emptyPipString,
      triggerPrice: order.triggerPrice || emptyPipString,
      triggerType: order.triggerType || 0,
      callbackRate: order.callbackRate || emptyPipString,
      conditionalOrderId: order.conditionalOrderId
        ? uuidToUint8Array(order.conditionalOrderId)
        : '0',
      isReduceOnly: !!order.isReduceOnly,
      timeInForce: order.timeInForce || 0,
      selfTradePrevention: order.selfTradePrevention || 0,
      delegatedPublicKey:
        order.delegatedPublicKey || ethers.constants.AddressZero,
      clientOrderId: order.clientOrderId || '',
    },
  ];
};

export const getTransferSignatureTypedData = (
  transfer: Transfer,
  contractAddress: string,
  chainId = hardhatChainId,
): Parameters<ethers.providers.JsonRpcSigner['_signTypedData']> => {
  return [
    getDomainSeparator(contractAddress, chainId),
    {
      Transfer: [
        { name: 'nonce', type: 'uint128' },
        { name: 'sourceWallet', type: 'address' },
        { name: 'destinationWallet', type: 'address' },
        { name: 'quantity', type: 'string' },
      ],
    },
    {
      nonce: uuidToUint8Array(transfer.nonce),
      sourceWallet: transfer.sourceWallet,
      destinationWallet: transfer.destinationWallet,
      quantity: transfer.quantity,
    },
  ];
};

export const getWithdrawalSignatureTypedData = (
  withdrawal: Withdrawal,
  contractAddress: string,
  chainId = hardhatChainId,
): Parameters<ethers.providers.JsonRpcSigner['_signTypedData']> => {
  return [
    getDomainSeparator(contractAddress, chainId),
    {
      Withdrawal: [
        { name: 'nonce', type: 'uint128' },
        { name: 'wallet', type: 'address' },
        { name: 'quantity', type: 'string' },
        { name: 'bridgeAdapter', type: 'address' },
        { name: 'bridgeAdapterPayload', type: 'bytes' },
      ],
    },
    {
      nonce: uuidToUint8Array(withdrawal.nonce),
      wallet: withdrawal.wallet,
      quantity: withdrawal.quantity,
      bridgeAdapter: withdrawal.bridgeAdapter,
      bridgeAdapterPayload: withdrawal.bridgeAdapterPayload,
    },
  ];
};

export const getPublishFundingMutiplierArguments = (
  baseAssetSymbol: string,
  fundingRate: string,
): [string, string] => {
  return [baseAssetSymbol, decimalToPips(fundingRate)];
};

export const getExecuteTradeArguments = (
  buyOrder: Order,
  buyWalletSignature: string,
  sellOrder: Order,
  sellWalletSignature: string,
  trade: Trade,
  buyDelegatedKeyAuthorization?: DelegatedKeyAuthorization,
  sellDelegatedKeyAuthorization?: DelegatedKeyAuthorization,
): [ExecuteTradeArgumentsStruct] => {
  return [
    {
      buy: orderToArgumentStruct(
        buyOrder,
        buyWalletSignature,
        buyDelegatedKeyAuthorization,
      ),
      sell: orderToArgumentStruct(
        sellOrder,
        sellWalletSignature,
        sellDelegatedKeyAuthorization,
      ),
      trade: tradeToArgumentStruct(trade, buyOrder),
    },
  ];
};

export const getTransferArguments = (
  transfer: Transfer,
  gasFee: string,
  walletSignature: string,
): [TransferStruct] => {
  return [
    {
      nonce: uuidToHexString(transfer.nonce),
      sourceWallet: transfer.sourceWallet,
      destinationWallet: transfer.destinationWallet,
      grossQuantity: decimalToPips(transfer.quantity),
      gasFee: decimalToPips(gasFee),
      walletSignature,
    },
  ];
};

export const getWithdrawArguments = (
  withdrawal: Withdrawal,
  gasFee: string,
  walletSignature: string,
): [WithdrawalStruct] => {
  return [
    {
      nonce: uuidToHexString(withdrawal.nonce),
      wallet: withdrawal.wallet,
      grossQuantity: decimalToPips(withdrawal.quantity),
      bridgeAdapter: withdrawal.bridgeAdapter,
      bridgeAdapterPayload: withdrawal.bridgeAdapterPayload,
      gasFee: decimalToPips(gasFee),
      walletSignature,
    },
  ];
};

export const indexPriceToArgumentStruct = (
  indexPriceAdapter: string,
  o: IndexPrice,
): IndexPricePayloadStruct => {
  return {
    indexPriceAdapter,
    payload: ethers.utils.defaultAbiCoder.encode(
      ['tuple(string,uint64,uint64)', 'bytes'],
      [
        [o.baseAssetSymbol, o.timestampInMs, decimalToPips(o.price)],
        o.signature,
      ],
    ),
  };
};

/**
 * Convert pips to native token quantity, taking the nunmber of decimals into account
 */
export const pipsToAssetUnits = (pips: string, decimals: number): string =>
  new BigNumber(pips)
    .shiftedBy(decimals - 8) // This is still correct when decimals < 8
    .integerValue(BigNumber.ROUND_DOWN)
    .toFixed(0);

export const uuidToHexString = (uuid: string): string =>
  `0x${uuid.replace(/-/g, '')}`;

const orderToArgumentStruct = (
  o: Order,
  walletSignature: string,
  delegatedKeyAuthorization?: DelegatedKeyAuthorization,
) => {
  const emptyPipString = '0.00000000';

  return {
    nonce: uuidToHexString(o.nonce),
    wallet: o.wallet,
    orderType: o.type,
    side: o.side,
    quantity: decimalToPips(o.quantity),
    limitPrice: decimalToPips(o.price || emptyPipString),
    triggerPrice: decimalToPips(o.triggerPrice || emptyPipString),
    triggerType: o.triggerType || 0,
    callbackRate: decimalToPips(o.callbackRate || emptyPipString),
    conditionalOrderId: o.conditionalOrderId || 0,
    clientOrderId: o.clientOrderId || '',
    isReduceOnly: !!o.isReduceOnly,
    timeInForce: o.timeInForce || 0,
    selfTradePrevention: o.selfTradePrevention || 0,
    walletSignature,
    isSignedByDelegatedKey: !!delegatedKeyAuthorization,
    delegatedKeyAuthorization: delegatedKeyAuthorization
      ? {
          nonce: uuidToHexString(delegatedKeyAuthorization.nonce),
          delegatedPublicKey: delegatedKeyAuthorization.delegatedPublicKey,
          signature: delegatedKeyAuthorization.signature,
        }
      : {
          nonce: 0,
          delegatedPublicKey: ethers.constants.AddressZero,
          signature: '0x',
        },
  };
};

const tradeToArgumentStruct = (t: Trade, order: Order) => {
  return {
    baseAssetSymbol: order.market.split('-')[0],
    quoteAssetSymbol: order.market.split('-')[1],
    baseQuantity: decimalToPips(t.baseQuantity),
    quoteQuantity: decimalToPips(t.quoteQuantity),
    makerFeeQuantity: decimalToPips(t.makerFeeQuantity),
    takerFeeQuantity: decimalToPips(t.takerFeeQuantity),
    price: decimalToPips(t.price),
    makerSide: t.makerSide,
  };
};

const uuidToUint8Array = (uuid: string): Uint8Array =>
  ethers.utils.arrayify(uuidToHexString(uuid));
