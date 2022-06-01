import BigNumber from 'bignumber.js';
import { ethers } from 'ethers';
import { ExchangeV4 } from '../typechain';

/** The fixed number of digits following the decimal in quantities expressed as pips */
export const pipsDecimals = 8;

export const signatureHashVersion = 5;

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
  GTT,
  IOC,
  FOK,
}

export enum OrderType {
  Market,
  Limit,
  LimitMaker,
  StopLoss,
  StopLossLimit,
  TakeProfit,
  TakeProfitLimit,
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
  timeInForce?: OrderTimeInForce;
  quantity: string;
  isQuantityInQuote: boolean;
  price: string;
  stopPrice?: string;
  clientOrderId?: string;
  selfTradePrevention?: OrderSelfTradePrevention;
  cancelAfter?: number;
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

/**
 * Convert pips to native token quantity, taking the nunmber of decimals into account
 */
export const pipsToAssetUnits = (pips: string, decimals: number): string =>
  new BigNumber(pips)
    .shiftedBy(decimals - 8) // This is still correct when decimals < 8
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

export const getOrderHash = (
  order: Order,
  delegatedKeyAuthorization?: DelegatedKeyAuthorization,
): string => {
  let params: TypeValuePair[] = [
    ['uint8', order.signatureHashVersion], // Signature hash version - only version 2 supported
    ['uint128', uuidToUint8Array(order.nonce)],
    ['address', order.wallet],
    ['string', order.market],
    ['uint8', order.type],
    ['uint8', order.side],
    ['string', order.quantity],
    ['bool', order.isQuantityInQuote],
    ['string', order.price || ''],
    ['string', order.stopPrice || ''],
    ['string', order.clientOrderId || ''],
    ['uint8', order.timeInForce || 0],
    ['uint8', order.selfTradePrevention || 0],
    ['uint64', order.cancelAfter || 0],
  ];

  if (delegatedKeyAuthorization) {
    params = [
      ...params,
      ['uint128', uuidToUint8Array(delegatedKeyAuthorization.nonce)],
      ['address', delegatedKeyAuthorization.delegatedPublicKey],
    ];
  }

  return solidityHashOfParams(params);
};

export const getDelegatedKeyAuthorizationHash = (
  walletAddress: string,
  delegatedKeyAuthorization: Omit<DelegatedKeyAuthorization, 'signature'>,
): string => {
  return solidityHashOfParams([
    ['uint128', uuidToUint8Array(delegatedKeyAuthorization.nonce)],
    ['address', walletAddress],
    ['address', delegatedKeyAuthorization.delegatedPublicKey],
  ]);
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
  oraclePrices: OraclePrice[],
  buyDelegatedKeyAuthorization?: DelegatedKeyAuthorization,
  sellDelegatedKeyAuthorization?: DelegatedKeyAuthorization,
): ExchangeV4['executeOrderBookTrade']['arguments'] => {
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
    oraclePrices.map(oraclePriceToArgumentStruct),
  ] as const;
};

export const getWithdrawArguments = (
  withdrawal: Withdrawal,
  gasFee: string,
  walletSignature: string,
  oraclePrices: OraclePrice[],
): ExchangeV4['withdraw']['arguments'] => {
  return [
    {
      nonce: uuidToHexString(withdrawal.nonce),
      walletAddress: withdrawal.wallet,
      grossQuantityInPips: decimalToPips(withdrawal.quantity),
      gasFeeInPips: decimalToPips(gasFee),
      walletSignature,
    },
    oraclePrices,
  ];
};

export const uuidToHexString = (uuid: string): string =>
  `0x${uuid.replace(/-/g, '')}`;

export const uuidToUint8Array = (uuid: string): Uint8Array =>
  ethers.utils.arrayify(uuidToHexString(uuid));

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

const oraclePriceToArgumentStruct = (
  o: OraclePrice,
  collateralAssetDecimals: number,
) => {
  return {
    baseAssetSymbol: o.baseAssetSymbol,
    timestampInMs: o.timestampInMs,
    priceInAssetUnits: decimalToAssetUnits(
      o.priceInAssetUnits,
      collateralAssetDecimals,
    ),
    signature: o.signature,
  };
};

const orderToArgumentStruct = (
  o: Order,
  walletSignature: string,
  delegatedKeyAuthorization?: DelegatedKeyAuthorization,
) => {
  return {
    signatureHashVersion: o.signatureHashVersion,
    nonce: uuidToHexString(o.nonce),
    walletAddress: o.wallet,
    orderType: o.type,
    side: o.side,
    quantityInPips: decimalToPips(o.quantity),
    isQuantityInQuote: o.isQuantityInQuote,
    limitPriceInPips: decimalToPips(o.price || '0'),
    stopPriceInPips: decimalToPips(o.stopPrice || '0'),
    clientOrderId: o.clientOrderId || '',
    timeInForce: o.timeInForce || 0,
    selfTradePrevention: o.selfTradePrevention || 0,
    cancelAfter: o.cancelAfter || 0,
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
    baseQuantityInPips: decimalToPips(t.baseQuantity),
    quoteQuantityInPips: decimalToPips(t.quoteQuantity),
    makerFeeQuantityInPips: decimalToPips(t.makerFeeQuantity),
    takerFeeQuantityInPips: decimalToPips(t.takerFeeQuantity),
    priceInPips: decimalToPips(t.price),
    makerSide: t.makerSide,
  };
};
