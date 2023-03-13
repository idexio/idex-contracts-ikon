import { ethers } from 'hardhat';
import { v1 as uuidv1, v4 as uuidv4 } from 'uuid';

import {
  deployAndAssociateContracts,
  expect,
  getLatestBlockTimestampInSeconds,
} from './helpers';
import { Exchange_v4 } from '../typechain-types';
import { uuidToHexString } from '../lib';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

describe('Exchange', function () {
  describe('invalidateNonce', async function () {
    let exchange: Exchange_v4;
    let traderWallet: SignerWithAddress;

    beforeEach(async () => {
      const wallets = await ethers.getSigners();
      traderWallet = wallets[1];
      const results = await deployAndAssociateContracts(wallets[0]);
      exchange = results.exchange;
    });

    it('should work on initial call', async function () {
      await exchange
        .connect(traderWallet)
        .invalidateNonce(uuidToHexString(uuidv1()));
    });

    it('should work on subsequent valid call', async function () {
      await exchange
        .connect(traderWallet)
        .invalidateNonce(uuidToHexString(uuidv1()));

      await exchange
        .connect(traderWallet)
        .invalidateNonce(uuidToHexString(uuidv1()));
    });

    it('should revert for wrong UUID version', async function () {
      await expect(
        exchange.invalidateNonce(uuidToHexString(uuidv4())),
      ).to.eventually.be.rejectedWith(/must be v1 uuid/i);
    });

    it('should revert for timestamp too far in the future', async function () {
      await expect(
        exchange.invalidateNonce(
          uuidToHexString(
            uuidv1({
              msecs:
                (await getLatestBlockTimestampInSeconds()) * 1000 +
                48 * 60 * 60 * 1000,
            }), // 2 days, max is 1
          ),
        ),
      ).to.eventually.be.rejectedWith(/nonce timestamp too high/i);
    });

    it('should revert on invalidating same timestamp twice', async function () {
      const uuid = uuidv1();

      await exchange
        .connect(traderWallet)
        .invalidateNonce(uuidToHexString(uuid));

      await expect(
        exchange.connect(traderWallet).invalidateNonce(uuidToHexString(uuid)),
      ).to.eventually.be.rejectedWith(/nonce timestamp invalidated/i);
    });

    it('should revert on subsequent call before block threshold of previous', async () => {
      await exchange.setChainPropagationPeriod(10);

      await exchange
        .connect(traderWallet)
        .invalidateNonce(uuidToHexString(uuidv1()));

      await expect(
        exchange
          .connect(traderWallet)
          .invalidateNonce(uuidToHexString(uuidv1())),
      ).to.eventually.be.rejectedWith(/last invalidation not finalized/i);
    });
  });
});
