import BigNumber from 'bignumber.js';
import { ethers } from 'ethers';
import {
  OraclePriceStruct,
  OrderBookTradeStruct,
  OrderStruct,
  WithdrawalStruct,
} from '../typechain-types/contracts/Exchange.sol/Exchange_v4';

import * as contracts from './contracts';

export {
  OraclePriceStruct,
  OrderBookTradeStruct,
  OrderStruct,
  WithdrawalStruct,
};

export { contracts };

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

export interface OraclePrice {
  baseAssetSymbol: string;
  timestampInMs: number;
  priceInAssetUnits: string;
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
  price: string;
  makerSide: OrderSide;
}

export interface Withdrawal {
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

export const getOraclePriceHash = (
  oraclePrice: Omit<OraclePrice, 'signature'>,
): string => {
  return solidityHashOfParams([
    ['string', oraclePrice.baseAssetSymbol],
    ['uint64', oraclePrice.timestampInMs],
    ['uint256', oraclePrice.priceInAssetUnits],
  ]);
};

export const getOrderHash = (order: Order): string => {
  const emptyPipString = '0.00000000';

  let params: TypeValuePair[] = [
    ['uint8', order.signatureHashVersion], // Signature hash version - only version 2 supported
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

  console.log(params);

  return solidityHashOfParams(params);
};

export const getDelegatedKeyAuthorizationHash = (
  delegatedKeyAuthorization: Omit<DelegatedKeyAuthorization, 'signature'>,
): string => {
  console.log(delegatedKeyAuthorization);
  const delegateKeyFragment = delegatedKeyAuthorization
    ? `delegated ${addressToUintString(
        delegatedKeyAuthorization.delegatedPublicKey,
      )}`
    : '';
  const message = `Hello from the IDEX team! Sign this message to prove you have control of this wallet. This won't cost you any gas fees.

Message:
${delegateKeyFragment}${uuidToUintString(delegatedKeyAuthorization.nonce)}`;
  console.log(message);
  return solidityHashOfParams([['string', message]]);
};

export const getWithdrawalHash = (withdrawal: Withdrawal): string => {
  return solidityHashOfParams([
    ['uint128', uuidToUint8Array(withdrawal.nonce)],
    ['address', withdrawal.wallet],
    ['string', withdrawal.quantity],
  ]);
};

export const getExecuteOrderBookTradeArguments = (
  buyOrder: Order,
  buyWalletSignature: string,
  sellOrder: Order,
  sellWalletSignature: string,
  trade: Trade,
  buyOraclePrices: OraclePrice[],
  sellOraclePrices: OraclePrice[],
  buyDelegatedKeyAuthorization?: DelegatedKeyAuthorization,
  sellDelegatedKeyAuthorization?: DelegatedKeyAuthorization,
): [
  OrderStruct,
  OrderStruct,
  OrderBookTradeStruct,
  OraclePrice[],
  OraclePrice[],
] => {
  return [
    orderToArgumentStruct(
      buyOrder,
      buyWalletSignature,
      buyDelegatedKeyAuthorization,
    ),
    orderToArgumentStruct(
      sellOrder,
      sellWalletSignature,
      sellDelegatedKeyAuthorization,
    ),
    tradeToArgumentStruct(trade, buyOrder),
    buyOraclePrices.map(oraclePriceToArgumentStruct),
    sellOraclePrices.map(oraclePriceToArgumentStruct),
  ];
};

export const getWithdrawArguments = (
  withdrawal: Withdrawal,
  gasFee: string,
  walletSignature: string,
  oraclePrices: OraclePrice[],
): [WithdrawalStruct, OraclePriceStruct[]] => {
  return [
    {
      nonce: uuidToHexString(withdrawal.nonce),
      wallet: withdrawal.wallet,
      grossQuantityInPips: decimalToPips(withdrawal.quantity),
      gasFeeInPips: decimalToPips(gasFee),
      walletSignature,
    },
    oraclePrices,
  ];
};

/**
 * Convert pips to native token quantity, taking the nunmber of decimals into account
 */
export const pipsToAssetUnits = (pips: string, decimals: number): string =>
  new BigNumber(pips)
    .shiftedBy(decimals - 8) // This is still correct when decimals < 8
    .integerValue(BigNumber.ROUND_DOWN)
    .toFixed(0);

const addressToUintString = (address: string): string =>
  new BigNumber(address.toLowerCase()).toFixed(0);

const oraclePriceToArgumentStruct = (o: OraclePrice) => {
  return {
    baseAssetSymbol: o.baseAssetSymbol,
    timestampInMs: o.timestampInMs,
    priceInAssetUnits: o.priceInAssetUnits,
    signature: o.signature,
  };
};

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
    quantityInPips: decimalToPips(o.quantity),
    limitPriceInPips: decimalToPips(o.price || emptyPipString),
    triggerPriceInPips: decimalToPips(o.triggerPrice || emptyPipString),
    triggerType: o.triggerType || 0,
    callbackRateInPips: decimalToPips(o.callbackRate || emptyPipString),
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
    baseQuantityInPips: decimalToPips(t.baseQuantity),
    quoteQuantityInPips: decimalToPips(t.quoteQuantity),
    makerFeeQuantityInPips: decimalToPips(t.makerFeeQuantity),
    takerFeeQuantityInPips: decimalToPips(t.takerFeeQuantity),
    priceInPips: decimalToPips(t.price),
    makerSide: t.makerSide,
  };
};

const uuidToHexString = (uuid: string): string => `0x${uuid.replace(/-/g, '')}`;

const uuidToUint8Array = (uuid: string): Uint8Array =>
  ethers.utils.arrayify(uuidToHexString(uuid));

const uuidToUintString = (uuid: string): string =>
  new BigNumber(`0x${uuid.replace(/-/g, '')}`).toFixed(0);
