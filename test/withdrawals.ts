import { ethers } from 'hardhat';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { v1 as uuidv1 } from 'uuid';

import {
  decimalToPips,
  getWithdrawArguments,
  getWithdrawalHash,
  signatureHashVersion,
  Withdrawal,
} from '../lib';
import { Exchange_v4 } from '../typechain-types';
import {
  deployAndAssociateContracts,
  expect,
  quoteAssetDecimals,
} from './helpers';

describe('Exchange', function () {
  describe('withdraw', function () {
    let dispatcherWallet: SignerWithAddress;
    let exchange: Exchange_v4;
    let signature: string;
    let withdrawal: Withdrawal;

    beforeEach(async () => {
      const wallets = await ethers.getSigners();
      dispatcherWallet = wallets[0];
      const traderWallet = wallets[7];
      const results = await deployAndAssociateContracts(
        wallets[1],
        dispatcherWallet,
        wallets[3],
        wallets[4],
        wallets[5],
        wallets[6],
      );
      exchange = results.exchange;

      const depositQuantity = ethers.utils.parseUnits(
        '5.0',
        quoteAssetDecimals,
      );
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
      };
      signature = await traderWallet.signMessage(
        ethers.utils.arrayify(getWithdrawalHash(withdrawal)),
      );
    });

    it('should work', async function () {
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
  });
});
