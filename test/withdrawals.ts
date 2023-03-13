import { ethers } from 'hardhat';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { v1 as uuidv1 } from 'uuid';

import {
  decimalToPips,
  getWithdrawArguments,
  getWithdrawalHash,
  indexPriceToArgumentStruct,
  signatureHashVersion,
  Withdrawal,
} from '../lib';
import { Exchange_v4, USDC } from '../typechain-types';
import {
  baseAssetSymbol,
  buildIndexPrice,
  buildIndexPriceWithValue,
  deployAndAssociateContracts,
  expect,
  executeTrade,
  fundWallets,
  quoteAssetDecimals,
} from './helpers';

describe('Exchange', function () {
  let dispatcherWallet: SignerWithAddress;
  let exchange: Exchange_v4;
  let exitFundWallet: SignerWithAddress;
  let feeWallet: SignerWithAddress;
  let indexPriceServiceWallet: SignerWithAddress;
  let signature: string;
  let traderWallet: SignerWithAddress;
  let usdc: USDC;
  let withdrawal: Withdrawal;

  beforeEach(async () => {
    const wallets = await ethers.getSigners();
    dispatcherWallet = wallets[0];
    exitFundWallet = wallets[3];
    feeWallet = wallets[4];
    indexPriceServiceWallet = wallets[5];
    traderWallet = wallets[7];
    const results = await deployAndAssociateContracts(
      wallets[1],
      dispatcherWallet,
      exitFundWallet,
      feeWallet,
      indexPriceServiceWallet,
      wallets[6],
    );
    exchange = results.exchange;
    usdc = results.usdc;

    const depositQuantity = ethers.utils.parseUnits('5.0', quoteAssetDecimals);
    await results.usdc.transfer(traderWallet.address, depositQuantity);
    await results.usdc
      .connect(traderWallet)
      .approve(exchange.address, depositQuantity);
    await (
      await exchange
        .connect(traderWallet)
        .deposit(depositQuantity, ethers.constants.AddressZero)
    ).wait();

    withdrawal = {
      signatureHashVersion,
      nonce: uuidv1(),
      wallet: traderWallet.address,
      quantity: '1.00000000',
      bridgeAdapter: ethers.constants.AddressZero,
      bridgeAdapterPayload: '0x',
    };
    signature = await traderWallet.signMessage(
      ethers.utils.arrayify(getWithdrawalHash(withdrawal)),
    );
  });

  describe('skim', function () {
    it('should work when Exchange is holding token', async function () {
      const tokenQuantity = 100000;
      await usdc.transfer(exchange.address, tokenQuantity);
      await exchange.skim(usdc.address);

      const transferEvents = await usdc.queryFilter(usdc.filters.Transfer());
      const transferToFeeWalletEvent =
        transferEvents[transferEvents.length - 1];
      expect(transferToFeeWalletEvent.args?.from).to.equal(exchange.address);
      expect(transferToFeeWalletEvent.args?.to).to.equal(feeWallet.address);
      expect(transferToFeeWalletEvent.args?.value).to.equal(tokenQuantity);
    });

    it('should revert when not called by admin wallet', async function () {
      await expect(
        exchange.connect(dispatcherWallet).skim(usdc.address),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });

    it('should revert for invalid token address', async function () {
      await expect(
        exchange.skim(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid token address/i);
    });
  });

  describe('withdraw', function () {
    it('should work with no gas fee', async function () {
      await exchange
        .connect(dispatcherWallet)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00000000', signature));

      const withdrawnEvents = await exchange.queryFilter(
        exchange.filters.Withdrawn(),
      );
      expect(withdrawnEvents).to.have.lengthOf(1);
      expect(withdrawnEvents[0].args?.quantity).to.equal(
        decimalToPips('1.00000000'),
      );
    });

    it('should work with gas fee', async function () {
      await exchange
        .connect(dispatcherWallet)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00100000', signature));

      const withdrawnEvents = await exchange.queryFilter(
        exchange.filters.Withdrawn(),
      );
      expect(withdrawnEvents).to.have.lengthOf(1);
      expect(withdrawnEvents[0].args?.quantity).to.equal(
        decimalToPips('1.00000000'),
      );
    });

    it('should work for EF after block delay', async function () {
      const trader2Wallet = (await ethers.getSigners())[10];
      await fundWallets([traderWallet, trader2Wallet], exchange, usdc);

      await executeTrade(
        exchange,
        dispatcherWallet,
        await buildIndexPrice(indexPriceServiceWallet),
        traderWallet,
        trader2Wallet,
      );

      await exchange.connect(traderWallet).exitWallet();
      await exchange.withdrawExit(traderWallet.address);

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '1900.00000000',
              baseAssetSymbol,
            ),
          ),
        ]);

      await exchange.connect(dispatcherWallet).deleverageExitFundClosure({
        baseAssetSymbol,
        counterpartyWallet: trader2Wallet.address,
        liquidatingWallet: exitFundWallet.address,
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('19000.00000000'),
      });

      // Expire EF withdraw delay
      await mine(300000, { interval: 0 });

      withdrawal.wallet = exitFundWallet.address;
      withdrawal.quantity = '1.00000000';
      signature = await exitFundWallet.signMessage(
        ethers.utils.arrayify(getWithdrawalHash(withdrawal)),
      );

      await exchange
        .connect(dispatcherWallet)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00100000', signature));

      const withdrawnEvents = await exchange.queryFilter(
        exchange.filters.Withdrawn(),
      );
      expect(withdrawnEvents).to.have.lengthOf(1);
      expect(withdrawnEvents[0].args?.quantity).to.equal(
        decimalToPips('1.00000000'),
      );
    });

    it('should revert for EF before block delay', async function () {
      const trader2Wallet = (await ethers.getSigners())[10];
      await fundWallets([traderWallet, trader2Wallet], exchange, usdc);

      await executeTrade(
        exchange,
        dispatcherWallet,
        await buildIndexPrice(indexPriceServiceWallet),
        traderWallet,
        trader2Wallet,
      );

      await exchange.connect(traderWallet).exitWallet();
      await exchange.withdrawExit(traderWallet.address);

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '1900.00000000',
              baseAssetSymbol,
            ),
          ),
        ]);

      await exchange.connect(dispatcherWallet).deleverageExitFundClosure({
        baseAssetSymbol,
        counterpartyWallet: trader2Wallet.address,
        liquidatingWallet: exitFundWallet.address,
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('19000.00000000'),
      });

      withdrawal.wallet = exitFundWallet.address;
      withdrawal.quantity = '1.00000000';
      signature = await exitFundWallet.signMessage(
        ethers.utils.arrayify(getWithdrawalHash(withdrawal)),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .withdraw(
            ...getWithdrawArguments(withdrawal, '0.00100000', signature),
          ),
      ).to.eventually.be.rejectedWith(/EF position opened too recently/i);
    });

    it('should revert when replayed', async function () {
      await exchange
        .connect(dispatcherWallet)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00000000', signature));

      await expect(
        exchange
          .connect(dispatcherWallet)
          .withdraw(
            ...getWithdrawArguments(withdrawal, '0.00000000', signature),
          ),
      ).to.eventually.be.rejectedWith(/duplicate withdrawal/i);
    });

    it('should revert on excessive withdrawal fee', async function () {
      await expect(
        exchange
          .connect(dispatcherWallet)
          .withdraw(
            ...getWithdrawArguments(withdrawal, '1.00000000', signature),
          ),
      ).to.eventually.be.rejectedWith(/excessive withdrawal fee/i);
    });

    it('should revert for exited wallet', async function () {
      await exchange.connect(traderWallet).exitWallet();
      await exchange.withdrawExit(traderWallet.address);

      await expect(
        exchange
          .connect(dispatcherWallet)
          .withdraw(
            ...getWithdrawArguments(withdrawal, '1.00000000', signature),
          ),
      ).to.eventually.be.rejectedWith(/wallet exited/i);
    });

    it('should revert when not sent by dispatcher', async function () {
      await expect(
        exchange.withdraw(
          ...getWithdrawArguments(withdrawal, '1.00000000', signature),
        ),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher wallet/i);
    });

    it('should revert for invalid signature hash version', async function () {
      withdrawal.signatureHashVersion = 177;
      signature = await traderWallet.signMessage(
        ethers.utils.arrayify(getWithdrawalHash(withdrawal)),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .withdraw(
            ...getWithdrawArguments(withdrawal, '0.00000000', signature),
          ),
      ).to.eventually.be.rejectedWith(/signature hash version invalid/i);
    });

    it('should revert for invalid signature', async function () {
      signature = await dispatcherWallet.signMessage(
        ethers.utils.arrayify(getWithdrawalHash(withdrawal)),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .withdraw(
            ...getWithdrawArguments(withdrawal, '0.00000000', signature),
          ),
      ).to.eventually.be.rejectedWith(/invalid wallet signature/i);
    });

    it('should revert for invalid bridge adapter', async function () {
      withdrawal.bridgeAdapter = dispatcherWallet.address;
      signature = await traderWallet.signMessage(
        ethers.utils.arrayify(getWithdrawalHash(withdrawal)),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .withdraw(
            ...getWithdrawArguments(withdrawal, '0.00000000', signature),
          ),
      ).to.eventually.be.rejectedWith(/invalid bridge adapter/i);
    });
  });
});
