import { v1 as uuidv1 } from 'uuid';
import { ethers, network } from 'hardhat';

import { Exchange_v4, USDC } from '../typechain-types';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import {
  decimalToPips,
  getTransferArguments,
  getTransferHash,
  signatureHashVersion,
  Transfer,
} from '../lib';
import {
  deployAndAssociateContracts,
  expect,
  quoteAssetDecimals,
  quoteAssetSymbol,
} from './helpers';

describe('Exchange', function () {
  let exchange: Exchange_v4;
  let exitFundWallet: SignerWithAddress;
  let indexPriceServiceWallet: SignerWithAddress;
  let insuranceFundWallet: SignerWithAddress;
  let ownerWallet: SignerWithAddress;
  let dispatcherWallet: SignerWithAddress;
  let signature: string;
  let trader1Wallet: SignerWithAddress;
  let trader2Wallet: SignerWithAddress;
  let transfer: Transfer;
  let usdc: USDC;

  before(async () => {
    await network.provider.send('hardhat_reset');
  });

  beforeEach(async () => {
    const wallets = await ethers.getSigners();

    const [feeWallet] = wallets;
    [
      ,
      dispatcherWallet,
      exitFundWallet,
      indexPriceServiceWallet,
      insuranceFundWallet,
      ownerWallet,
      trader1Wallet,
      trader2Wallet,
    ] = wallets;

    const results = await deployAndAssociateContracts(
      ownerWallet,
      dispatcherWallet,
      exitFundWallet,
      feeWallet,
      indexPriceServiceWallet,
      insuranceFundWallet,
    );
    exchange = results.exchange;
    usdc = results.usdc;

    const depositQuantity = ethers.utils.parseUnits('5.0', quoteAssetDecimals);
    await usdc.transfer(trader1Wallet.address, depositQuantity);
    await usdc
      .connect(trader1Wallet)
      .approve(exchange.address, depositQuantity);
    await (
      await exchange
        .connect(trader1Wallet)
        .deposit(depositQuantity, ethers.constants.AddressZero)
    ).wait();

    transfer = {
      signatureHashVersion,
      nonce: uuidv1(),
      sourceWallet: trader1Wallet.address,
      destinationWallet: trader2Wallet.address,
      quantity: '1.00000000',
    };
    signature = await trader1Wallet.signMessage(
      ethers.utils.arrayify(getTransferHash(transfer)),
    );
  });

  describe('transfer', function () {
    it('should work with no fee', async function () {
      await exchange
        .connect(dispatcherWallet)
        .transfer(...getTransferArguments(transfer, '0.00000000', signature));

      const transferEvents = await exchange.queryFilter(
        exchange.filters.Transferred(),
      );
      expect(transferEvents).to.have.lengthOf(1);
      expect(transferEvents[0].args?.quantity).to.equal(
        decimalToPips('1.00000000'),
      );

      expect(
        (
          await exchange.loadBalanceBySymbol(
            trader2Wallet.address,
            quoteAssetSymbol,
          )
        ).toString(),
      ).to.equal(decimalToPips('1.00000000'));
    });

    it('should work with fee', async function () {
      await exchange
        .connect(dispatcherWallet)
        .transfer(...getTransferArguments(transfer, '0.00100000', signature));

      const transferEvents = await exchange.queryFilter(
        exchange.filters.Transferred(),
      );
      expect(transferEvents).to.have.lengthOf(1);
      expect(transferEvents[0].args?.quantity).to.equal(
        decimalToPips('1.00000000'),
      );

      expect(
        (
          await exchange.loadBalanceBySymbol(
            trader2Wallet.address,
            quoteAssetSymbol,
          )
        ).toString(),
      ).to.equal(decimalToPips('0.99900000'));
    });

    it('should revert for excessive fee', async function () {
      await expect(
        exchange
          .connect(dispatcherWallet)
          .transfer(...getTransferArguments(transfer, '0.50000000', signature)),
      ).to.eventually.be.rejectedWith(/excessive transfer fee/i);
    });

    it('should revert when not sent by dispatcher', async function () {
      await expect(
        exchange.transfer(
          ...getTransferArguments(transfer, '0.00000000', signature),
        ),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher wallet/i);
    });

    it('should revert for invalid signature hash version', async function () {
      transfer.signatureHashVersion = 177;
      signature = await trader1Wallet.signMessage(
        ethers.utils.arrayify(getTransferHash(transfer)),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .transfer(...getTransferArguments(transfer, '0.00000000', signature)),
      ).to.eventually.be.rejectedWith(/signature hash version invalid/i);
    });

    it('should revert for exited wallet', async function () {
      await exchange.connect(trader1Wallet).exitWallet();

      await expect(
        exchange
          .connect(dispatcherWallet)
          .transfer(...getTransferArguments(transfer, '0.00000000', signature)),
      ).to.eventually.be.rejectedWith(/wallet exited/i);
    });

    it('should revert for EF source', async function () {
      transfer.sourceWallet = exitFundWallet.address;

      await expect(
        exchange
          .connect(dispatcherWallet)
          .transfer(...getTransferArguments(transfer, '0.00000000', signature)),
      ).to.eventually.be.rejectedWith(/cannot transfer from EF/i);
    });

    it('should revert for IF source', async function () {
      transfer.sourceWallet = insuranceFundWallet.address;

      await expect(
        exchange
          .connect(dispatcherWallet)
          .transfer(...getTransferArguments(transfer, '0.00000000', signature)),
      ).to.eventually.be.rejectedWith(/cannot transfer from IF/i);
    });

    it('should revert for zero destination', async function () {
      transfer.destinationWallet = ethers.constants.AddressZero;

      await expect(
        exchange
          .connect(dispatcherWallet)
          .transfer(...getTransferArguments(transfer, '0.00000000', signature)),
      ).to.eventually.be.rejectedWith(/invalid destination wallet/i);
    });

    it('should revert EF destination', async function () {
      transfer.destinationWallet = exitFundWallet.address;

      await expect(
        exchange
          .connect(dispatcherWallet)
          .transfer(...getTransferArguments(transfer, '0.00000000', signature)),
      ).to.eventually.be.rejectedWith(/cannot transfer to EF/i);
    });

    it('should revert on duplicate transfer', async function () {
      await exchange
        .connect(dispatcherWallet)
        .transfer(...getTransferArguments(transfer, '0.00000000', signature));

      await expect(
        exchange
          .connect(dispatcherWallet)
          .transfer(...getTransferArguments(transfer, '0.00000000', signature)),
      ).to.eventually.be.rejectedWith(/duplicate transfer/i);
    });

    it('should revert on invalid signature', async function () {
      transfer.quantity = '1.00000001';

      await expect(
        exchange
          .connect(dispatcherWallet)
          .transfer(...getTransferArguments(transfer, '0.00000000', signature)),
      ).to.eventually.be.rejectedWith(/invalid wallet signature/i);
    });
  });
});
