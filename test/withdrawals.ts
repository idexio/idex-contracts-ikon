import { ethers } from 'hardhat';
import { v1 as uuidv1 } from 'uuid';

import {
  decimalToPips,
  getWithdrawArguments,
  getWithdrawalHash,
  indexPriceToArgumentStruct,
} from '../lib';
import {
  buildIndexPrice,
  deployAndAssociateContracts,
  expect,
  quoteAssetDecimals,
} from './helpers';

describe('Exchange', function () {
  describe('withdraw', function () {
    it('should work', async function () {
      const [owner, dispatcher, trader, exitFund, fee, insurance, index] =
        await ethers.getSigners();
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
      await usdc.transfer(trader.address, depositQuantity);
      await usdc.connect(trader).approve(exchange.address, depositQuantity);
      await (await exchange.connect(trader).deposit(depositQuantity)).wait();

      const withdrawal = {
        nonce: uuidv1(),
        wallet: trader.address,
        quantity: '1.00000000',
      };
      const signature = await trader.signMessage(
        ethers.utils.arrayify(getWithdrawalHash(withdrawal)),
      );
      await (
        await exchange
          .connect(dispatcher)
          .withdraw(
            ...getWithdrawArguments(withdrawal, '0.00000000', signature, [
              indexPriceToArgumentStruct(await buildIndexPrice(index)),
            ]),
          )
      ).wait();

      const withdrawnEvents = await exchange.queryFilter(
        exchange.filters.Withdrawn(),
      );
      expect(withdrawnEvents).to.have.lengthOf(1);
      expect(withdrawnEvents[0].args?.quantity).to.equal(
        decimalToPips('1.00000000'),
      );
    });
  });
});
