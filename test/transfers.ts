import { ethers } from 'hardhat';
import { v1 as uuidv1 } from 'uuid';

import {
  decimalToPips,
  getTransferArguments,
  getTransferHash,
  signatureHashVersion,
} from '../lib';
import {
  buildIndexPrice,
  deployAndAssociateContracts,
  expect,
  quoteAssetDecimals,
  quoteAssetSymbol,
} from './helpers';

describe('Exchange', function () {
  describe.only('transfer', function () {
    it('should work', async function () {
      const [
        owner,
        dispatcher,
        trader1,
        trader2,
        exitFund,
        fee,
        insurance,
        index,
      ] = await ethers.getSigners();
      const { exchange, usdc } = await deployAndAssociateContracts(
        owner,
        dispatcher,
        exitFund,
        fee,
        insurance,
        index,
      );

      const depositQuantity = ethers.utils.parseUnits(
        '5.0',
        quoteAssetDecimals,
      );
      await usdc.transfer(trader1.address, depositQuantity);
      await usdc.connect(trader1).approve(exchange.address, depositQuantity);
      await (await exchange.connect(trader1).deposit(depositQuantity)).wait();

      const transfer = {
        signatureHashVersion,
        nonce: uuidv1(),
        sourceWallet: trader1.address,
        destinationWallet: trader2.address,
        quantity: '1.00000000',
      };
      const signature = await trader1.signMessage(
        ethers.utils.arrayify(getTransferHash(transfer)),
      );
      await (
        await exchange
          .connect(dispatcher)
          .transfer(
            ...getTransferArguments(transfer, '0.00000000', signature, [
              await buildIndexPrice(index),
            ]),
          )
      ).wait();

      const transferEvents = await exchange.queryFilter(
        exchange.filters.Transferred(),
      );
      expect(transferEvents).to.have.lengthOf(1);
      expect(transferEvents[0].args?.quantity).to.equal(
        decimalToPips('1.00000000'),
      );

      expect(
        (
          await exchange.loadBalanceBySymbol(trader2.address, quoteAssetSymbol)
        ).toString(),
      ).to.equal(decimalToPips('1.00000000'));
    });
  });
});
