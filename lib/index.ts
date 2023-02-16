import BigNumber from 'bignumber.js';
import { ethers } from 'ethers';
import { baseAssetSymbol } from '../test/helpers';
import {
  AcquisitionDeleverageArgumentsStruct,
  ClosureDeleverageArgumentsStruct,
  ExecuteOrderBookTradeArgumentsStruct,
  IndexPriceStruct,
  OrderBookTradeStruct,
  OrderStruct,
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
  ExecuteOrderBookTradeArgumentsStruct,
  IndexPriceStruct,
  OrderBookTradeStruct,
  OrderStruct,
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

export enum LiquidationType {
  WalletExited,
  WalletInMaintenance,
  WalletDuringSystemRecovery,
}

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
  signatureHashVersion: number;
  baseAssetSymbol: string;
  timestampInMs: number;
  price: string; // Decimal string
  signature: string;
}

export interface Order {
  signatureHashVersion: number;
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
  signatureHashVersion: number;
  nonce: string;
  delegatedPublicKey: string;
  signature: string;
}

export interface Trade {
  baseAssetSymbol: string;
  quoteAssetSymbol: string;
  baseQuantity: string;
  quoteQuantity: string;
  makerFeeQuantity: string;
  takerFeeQuantity: string;
  price: string; // Decimal string
  makerSide: OrderSide;
}

export interface Transfer {
  signatureHashVersion: number;
  nonce: string;
  sourceWallet: string;
  destinationWallet: string;
  quantity: string; // Decimal string
}

export interface Withdrawal {
  signatureHashVersion: number;
  nonce: string;
  wallet: string;
  quantity: string; // Decimal string
}

export const compareMarketSymbols = (a: string, b: string): number =>
  Buffer.compare(
    ethers.utils.arrayify(ethers.utils.solidityKeccak256(['string'], [a])),
    ethers.utils.arrayify(ethers.utils.solidityKeccak256(['string'], [b])),
  );

export const decimalToAssetUnits = (
  decimal: string,
  decimals: number,
): string => pipsToAssetUnits(decimalToPips(decimal), decimals);

/**
 * Convert decimal quantity string to integer pips as expected by contract structs. Truncates
 * anything beyond 8 decimals
 */
export const decimalToPips = (decimal: string): string =>
  new BigNumber(decimal)
    .shiftedBy(8)
    .integerValue(BigNumber.ROUND_DOWN)
    .toFixed(0);

export const getIndexPriceHash = (
  indexPrice: Omit<IndexPrice, 'signature'>,
  quoteAssetSymbol: string,
): string => {
  return solidityHashOfParams([
    ['uint8', indexPrice.signatureHashVersion],
    ['string', indexPrice.baseAssetSymbol],
    ['string', quoteAssetSymbol],
    ['uint64', indexPrice.timestampInMs],
    ['string', indexPrice.price],
  ]);
};

export const getOrderHash = (order: Order): string => {
  const emptyPipString = '0.00000000';

  let params: TypeValuePair[] = [
    ['uint8', order.signatureHashVersion],
    ['uint128', uuidToUint8Array(order.nonce)],
    ['address', order.wallet],
    ['string', order.market],
    ['uint8', order.type],
    ['uint8', order.side],
    ['string', order.quantity],
    ['string', order.price || emptyPipString],
    ['string', order.triggerPrice || emptyPipString],
    ['uint8', order.triggerType || 0],
    ['string', order.callbackRate || emptyPipString],
    [
      'uint128',
      order.conditionalOrderId
        ? uuidToUint8Array(order.conditionalOrderId)
        : '0',
    ],
    ['bool', !!order.isReduceOnly],
    ['uint8', order.timeInForce || 0],
    ['uint8', order.selfTradePrevention || 0],
    ['address', order.delegatedPublicKey || ethers.constants.AddressZero],
    ['string', order.clientOrderId || ''],
  ];

  return solidityHashOfParams(params);
};

export const getDelegatedKeyAuthorizationMessage = (
  delegatedKeyAuthorization: Omit<DelegatedKeyAuthorization, 'signature'>,
): string => {
  const delegateKeyFragment = delegatedKeyAuthorization
    ? `delegated ${addressToUintString(
        delegatedKeyAuthorization.delegatedPublicKey,
      )}`
    : '';
  const message = `Hello from the IDEX team! Sign this message to prove you have control of this wallet. This won't cost you any gas fees.

Message:
${delegateKeyFragment}${uuidToUintString(delegatedKeyAuthorization.nonce)}`;

  return message;
};

export const getTransferHash = (transfer: Transfer): string => {
  return solidityHashOfParams([
    ['uint8', transfer.signatureHashVersion],
    ['uint128', uuidToUint8Array(transfer.nonce)],
    ['address', transfer.sourceWallet],
    ['address', transfer.destinationWallet],
    ['string', transfer.quantity],
  ]);
};

export const getWithdrawalHash = (withdrawal: Withdrawal): string => {
  return solidityHashOfParams([
    ['uint8', withdrawal.signatureHashVersion],
    ['uint128', uuidToUint8Array(withdrawal.nonce)],
    ['address', withdrawal.wallet],
    ['string', withdrawal.quantity],
  ]);
};

export const getPublishFundingMutiplierArguments = (
  baseAssetSymbol: string,
  fundingRate: string,
): [string, string] => {
  return [baseAssetSymbol, decimalToPips(fundingRate)];
};

export const getExecuteOrderBookTradeArguments = (
  buyOrder: Order,
  buyWalletSignature: string,
  sellOrder: Order,
  sellWalletSignature: string,
  trade: Trade,
  buyDelegatedKeyAuthorization?: DelegatedKeyAuthorization,
  sellDelegatedKeyAuthorization?: DelegatedKeyAuthorization,
): [ExecuteOrderBookTradeArgumentsStruct] => {
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
      orderBookTrade: tradeToArgumentStruct(trade, buyOrder),
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
      signatureHashVersion: transfer.signatureHashVersion,
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
      signatureHashVersion: withdrawal.signatureHashVersion,
      nonce: uuidToHexString(withdrawal.nonce),
      wallet: withdrawal.wallet,
      grossQuantity: decimalToPips(withdrawal.quantity),
      gasFee: decimalToPips(gasFee),
      walletSignature,
    },
  ];
};

export const indexPriceToArgumentStruct = (o: IndexPrice) => {
  return {
    signatureHashVersion: o.signatureHashVersion,
    baseAssetSymbol: o.baseAssetSymbol,
    timestampInMs: o.timestampInMs,
    price: decimalToPips(o.price),
    signature: o.signature,
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

const addressToUintString = (address: string): string =>
  new BigNumber(address.toLowerCase()).toFixed(0);

const orderToArgumentStruct = (
  o: Order,
  walletSignature: string,
  delegatedKeyAuthorization?: DelegatedKeyAuthorization,
) => {
  const emptyPipString = '0.00000000';

  return {
    signatureHashVersion: o.signatureHashVersion,
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
          signatureHashVersion: delegatedKeyAuthorization.signatureHashVersion,
          nonce: uuidToHexString(delegatedKeyAuthorization.nonce),
          delegatedPublicKey: delegatedKeyAuthorization.delegatedPublicKey,
          signature: delegatedKeyAuthorization.signature,
        }
      : {
          signatureHashVersion: 0,
          nonce: 0,
          delegatedPublicKey: ethers.constants.AddressZero,
          signature: '0x',
        },
  };
};

type TypeValuePair =
  | ['string' | 'address', string]
  | ['uint128' | 'uint256', string | Uint8Array]
  | ['uint8' | 'uint32' | 'uint64', number]
  | ['bool', boolean];

const solidityHashOfParams = (params: TypeValuePair[]): string => {
  const fields = params.map((param) => param[0]);
  const values = params.map((param) => param[1]);
  return ethers.utils.solidityKeccak256(fields, values);
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

const uuidToUintString = (uuid: string): string =>
  new BigNumber(`0x${uuid.replace(/-/g, '')}`).toFixed(0);
