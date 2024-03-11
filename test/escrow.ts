import { v1 as uuidv1 } from 'uuid';
import { ethers, network } from 'hardhat';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';

import {
  EarningsEscrow,
  EarningsEscrow__factory,
  USDC,
} from '../typechain-types';
import { expect } from './helpers';

import {
  getStakingDistributionHash,
  getStakingEscrowDistributeArguments,
  SignedAssetDistribution,
} from '../lib';

describe('EarningsEscrow', function () {
  let EarningsEscrowFactory: EarningsEscrow__factory;
  let owner: SignerWithAddress;
  let usdc: USDC;

  before(async () => {
    await network.provider.send('hardhat_reset');
    EarningsEscrowFactory = await ethers.getContractFactory('EarningsEscrow');
  });

  beforeEach(async () => {
    [owner] = await ethers.getSigners();
    usdc = await (
      await (await ethers.getContractFactory('USDC')).connect(owner).deploy()
    ).waitForDeployment();
  });

  describe('constructor', () => {
    it('should work', async () => {
      await EarningsEscrowFactory.deploy(await usdc.getAddress(), owner);
    });

    it('should fail for non-contract token address', async () => {
      await expect(
        EarningsEscrowFactory.deploy(
          '0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
          owner,
        ),
      ).to.eventually.be.rejectedWith(/invalid asset address/i);
    });
  });

  describe('assetAddress', () => {
    it('should work with an ERC20 token', async () => {
      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );
      const assetAddress = await escrow.assetAddress();
      expect(assetAddress).to.equal(await usdc.getAddress());
    });

    it('should work with native asset', async () => {
      const escrow = await EarningsEscrowFactory.deploy(
        ethers.ZeroAddress,
        owner,
      );
      const assetAddress = await escrow.assetAddress();
      expect(assetAddress).to.equal(ethers.ZeroAddress);
    });
  });

  describe('loadTotalDistributed', () => {
    it('should fail with zero address', async () => {
      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );
      await expect(
        escrow.loadTotalDistributed(ethers.ZeroAddress),
      ).to.eventually.be.rejectedWith(/invalid wallet address/i);
    });
  });

  describe('setAdmin', async () => {
    let escrow: EarningsEscrow;

    beforeEach(async () => {
      escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );
    });

    it('should work for valid address', async () => {
      await escrow.setAdmin((await ethers.getSigners())[1]);
    });

    it('should revert for empty address', async () => {
      await expect(
        escrow.setAdmin(ethers.ZeroAddress),
      ).to.eventually.be.rejectedWith(/invalid wallet address/i);
    });

    it('should revert for setting same address as current', async () => {
      const wallet = (await ethers.getSigners())[1];

      await escrow.setAdmin(wallet);

      await expect(escrow.setAdmin(wallet)).to.eventually.be.rejectedWith(
        /must be different from current admin/i,
      );
    });

    it('should revert when not called by owner', async () => {
      const wallet = (await ethers.getSigners())[1];

      await expect(
        escrow.connect(wallet).setAdmin(wallet),
      ).to.eventually.be.rejectedWith(/caller must be owner/i);
    });
  });

  describe('removeAdmin', async () => {
    it('should work', async () => {
      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );

      await escrow.removeAdmin();
    });
  });

  describe('setExchange', () => {
    let escrow: EarningsEscrow;

    beforeEach(async () => {
      escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );
    });

    it('should work', async () => {
      const exchange = (await ethers.getSigners())[1];

      await escrow.setExchange(exchange.address);

      const events = await escrow.queryFilter(escrow.filters.ExchangeChanged());
      expect(events).to.be.an('array');
      expect(events).to.have.lengthOf(1);
      expect(events[0].args?.previousValue).to.equal(owner.address);
      expect(events[0].args?.newValue).to.equal(exchange.address);
    });

    it('should fail for non-admin caller', async () => {
      const exchange = (await ethers.getSigners())[1];

      await expect(
        escrow.connect(exchange).setExchange(exchange.address),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });

    it('should fail for invalid address', async () => {
      await expect(
        escrow.setExchange(ethers.ZeroAddress),
      ).to.eventually.be.rejectedWith(/invalid wallet address/i);
    });

    it('should fail setting same address', async () => {
      await expect(
        escrow.setExchange(owner.address),
      ).to.eventually.be.rejectedWith(
        /must be different from current exchange/i,
      );
    });
  });

  describe('removeExchange', () => {
    it('should work', async () => {
      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );

      const exchange = (await ethers.getSigners())[1];

      await escrow.setExchange(exchange.address);
      await escrow.removeExchange();

      const events = await escrow.queryFilter(escrow.filters.ExchangeChanged());
      expect(events).to.be.an('array');
      expect(events).to.have.lengthOf(2);
      expect(events[1].args?.previousValue).to.equal(exchange.address);
      expect(events[1].args?.newValue).to.equal(ethers.ZeroAddress);
    });

    it('should fail for non-admin caller', async () => {
      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );

      await expect(
        escrow.connect((await ethers.getSigners())[1]).removeExchange(),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });

  describe('distribute', () => {
    it('should work for native token', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const depositQuantity = ethers.parseEther('1.0');
      const distributionQuantity = ethers.parseEther('0.5');

      const escrow = await EarningsEscrowFactory.deploy(
        ethers.ZeroAddress,
        owner,
      );
      await owner.sendTransaction({
        to: await escrow.getAddress(),
        value: depositQuantity,
      });

      await escrow
        .connect(targetWallet)
        .distribute(
          ...getStakingEscrowDistributeArguments(
            await getSignedDistribution(
              await escrow.getAddress(),
              '00000000-0000-0000-0000-000000000000',
              owner,
              targetWallet.address,
              ethers.ZeroAddress,
              distributionQuantity,
            ),
          ),
        );

      const events = await escrow.queryFilter(
        escrow.filters.AssetsDistributed(),
      );
      expect(events).to.be.an('array');
      expect(events).to.have.lengthOf(1);
      expect(events[0].args?.wallet).to.equal(targetWallet.address);
      expect(events[0].args?.quantity).to.equal(distributionQuantity);
      expect(events[0].args?.totalQuantity).to.equal(distributionQuantity);

      const tokenEvents = await escrow.queryFilter(
        escrow.filters.NativeAssetEscrowed(),
      );
      expect(tokenEvents).to.be.an('array');
      expect(tokenEvents.length).to.equal(1);
      expect(tokenEvents[0].args?.from).to.equal(owner.address);
      expect(tokenEvents[0].args?.quantity).to.equal(depositQuantity);
    });

    it('should fail for native token when underfunded', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const depositQuantity = ethers.parseEther('1.0');
      const distributionQuantity = ethers.parseEther('5.0');

      const escrow = await EarningsEscrowFactory.deploy(
        ethers.ZeroAddress,
        owner,
      );
      await owner.sendTransaction({
        to: await escrow.getAddress(),
        value: depositQuantity,
      });

      await expect(
        escrow
          .connect(targetWallet)
          .distribute(
            ...getStakingEscrowDistributeArguments(
              await getSignedDistribution(
                await escrow.getAddress(),
                '00000000-0000-0000-0000-000000000000',
                owner,
                targetWallet.address,
                ethers.ZeroAddress,
                distributionQuantity,
              ),
            ),
          ),
      ).to.eventually.be.rejectedWith(/native asset transfer failed/i);
    });

    it('should work for token', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const quantity = BigInt(10000000);

      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );

      await usdc.transfer(await escrow.getAddress(), quantity);

      await escrow
        .connect(targetWallet)
        .distribute(
          ...getStakingEscrowDistributeArguments(
            await getSignedDistribution(
              await escrow.getAddress(),
              '00000000-0000-0000-0000-000000000000',
              owner,
              targetWallet.address,
              await usdc.getAddress(),
              quantity,
            ),
          ),
        );

      const events = await escrow.queryFilter(
        escrow.filters.AssetsDistributed(),
      );

      expect(events).to.be.an('array');
      expect(events).to.have.lengthOf(1);
      expect(events[0].args?.wallet).to.equal(targetWallet.address);
      expect(events[0].args?.quantity).to.equal(quantity);
      expect(events[0].args?.totalQuantity).to.equal(quantity);

      const tokenEvents = await usdc.queryFilter(usdc.filters.Transfer());
      expect(tokenEvents).to.be.an('array');
      expect(tokenEvents).to.have.lengthOf(3);
      expect(tokenEvents[2].args?.from).to.equal(await escrow.getAddress());
      expect(tokenEvents[2].args?.to).to.equal(targetWallet.address);
      expect(tokenEvents[2].args?.value).to.equal(quantity);
    });

    it('should work for token that takes fees', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const quantity = BigInt(20000000);
      const distributionQuantity = BigInt(10000000);

      const feeToken = await (
        await (await ethers.getContractFactory('USDC')).connect(owner).deploy()
      ).waitForDeployment();
      await feeToken.setFee(1);

      const escrow = await EarningsEscrowFactory.deploy(
        await feeToken.getAddress(),
        owner,
      );

      await feeToken.transfer(await escrow.getAddress(), quantity);

      await escrow
        .connect(targetWallet)
        .distribute(
          ...getStakingEscrowDistributeArguments(
            await getSignedDistribution(
              await escrow.getAddress(),
              '00000000-0000-0000-0000-000000000000',
              owner,
              targetWallet.address,
              await feeToken.getAddress(),
              distributionQuantity,
            ),
          ),
        );

      const events = await escrow.queryFilter(
        escrow.filters.AssetsDistributed(),
      );

      expect(events).to.be.an('array');
      expect(events).to.have.lengthOf(1);
    });

    it('should fail when underfunded', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const quantity = BigInt(10000000);
      const distributionQuantity = BigInt(20000000);

      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );
      await usdc.transfer(await escrow.getAddress(), quantity);

      await expect(
        escrow
          .connect(targetWallet)
          .distribute(
            ...getStakingEscrowDistributeArguments(
              await getSignedDistribution(
                await escrow.getAddress(),
                '00000000-0000-0000-0000-000000000000',
                owner,
                targetWallet.address,
                await usdc.getAddress(),
                distributionQuantity,
              ),
            ),
          ),
      ).to.eventually.be.rejectedWith(
        /ERC20: transfer amount exceeds balance/i,
      );
    });

    it('should fail when quote asset transfer fails', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const quantity = BigInt(20000000);
      const distributionQuantity = BigInt(10000000);

      await usdc.setIsTransferDisabled(true);

      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );

      await usdc.transfer(await escrow.getAddress(), quantity);

      await expect(
        escrow
          .connect(targetWallet)
          .distribute(
            ...getStakingEscrowDistributeArguments(
              await getSignedDistribution(
                await escrow.getAddress(),
                '00000000-0000-0000-0000-000000000000',
                owner,
                targetWallet.address,
                await usdc.getAddress(),
                distributionQuantity,
              ),
            ),
          ),
      ).to.eventually.be.rejectedWith(/token transfer failed/i);
    });

    it('should work for multiple distributions', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const quantity = BigInt(10000000);

      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );

      await usdc.transfer(await escrow.getAddress(), quantity * BigInt(10)); // Transfer in 10x

      const signedDistribution1 = await getSignedDistribution(
        await escrow.getAddress(),
        '00000000-0000-0000-0000-000000000000',
        owner,
        targetWallet.address,
        await usdc.getAddress(),
        quantity,
      );
      await escrow
        .connect(targetWallet)
        .distribute(
          ...getStakingEscrowDistributeArguments(signedDistribution1),
        );
      await escrow
        .connect(targetWallet)
        .distribute(
          ...getStakingEscrowDistributeArguments(
            await getSignedDistribution(
              await escrow.getAddress(),
              signedDistribution1.nonce,
              owner,
              targetWallet.address,
              await usdc.getAddress(),
              quantity,
            ),
          ),
        );

      const events = await escrow.queryFilter(
        escrow.filters.AssetsDistributed(),
      );
      expect(events).to.be.an('array');
      expect(events).to.have.lengthOf(2);
      expect(events[0].args?.wallet).to.equal(targetWallet.address);
      expect(events[0].args?.quantity).to.equal(quantity);
      expect(events[0].args?.totalQuantity).to.equal(quantity);
      expect(events[1].args?.wallet).to.equal(targetWallet.address);
      expect(events[1].args?.quantity).to.equal(quantity);
      expect(events[1].args?.totalQuantity).to.equal(
        (BigInt(quantity) * BigInt(2)).toString(),
      );
      const finalTotalQuantity = await escrow.loadTotalDistributed(
        targetWallet,
      );
      expect(finalTotalQuantity.toString(10)).to.equal(
        (BigInt(quantity) * BigInt(2)).toString(),
      );
    });

    it('should fail for invalid contract address', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const quantity = BigInt(10000000);

      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );

      await usdc.transfer(await escrow.getAddress(), quantity);

      await expect(
        escrow
          .connect(targetWallet)
          .distribute(
            ...getStakingEscrowDistributeArguments(
              await getSignedDistribution(
                '0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
                '00000000-0000-0000-0000-000000000000',
                owner,
                targetWallet.address,
                await usdc.getAddress(),
                quantity,
              ),
            ),
          ),
      ).to.eventually.be.rejectedWith(/invalid exchange signature/i);
    });

    it('should fail for non-exchange wallet', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const quantity = BigInt(10000000);

      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );
      await usdc.transfer(await escrow.getAddress(), quantity);

      await expect(
        escrow.distribute(
          ...getStakingEscrowDistributeArguments(
            await getSignedDistribution(
              '0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
              '00000000-0000-0000-0000-000000000000',
              owner,
              targetWallet.address,
              await usdc.getAddress(),
              quantity,
            ),
          ),
        ),
      ).to.eventually.be.rejectedWith(/invalid caller/i);
    });

    it('should fail for duplicate parent nonce', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const quantity = BigInt(10000000);

      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );
      await usdc.transfer(await escrow.getAddress(), quantity);

      await expect(
        escrow
          .connect(targetWallet)
          .distribute(
            ...getStakingEscrowDistributeArguments(
              await getSignedDistribution(
                '0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
                '00000000-0000-0000-0000-000000000000',
                owner,
                targetWallet.address,
                await usdc.getAddress(),
                quantity,
                '00000000-0000-0000-0000-000000000000',
              ),
            ),
          ),
      ).to.eventually.be.rejectedWith(/nonce must be different from parent/i);
    });

    it('should fail for invalidated nonce', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const quantity = BigInt(10000000);

      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );
      await usdc.transfer(await escrow.getAddress(), quantity);

      await escrow
        .connect(targetWallet)
        .distribute(
          ...getStakingEscrowDistributeArguments(
            await getSignedDistribution(
              await escrow.getAddress(),
              '00000000-0000-0000-0000-000000000000',
              owner,
              targetWallet.address,
              await usdc.getAddress(),
              quantity,
            ),
          ),
        );

      await expect(
        escrow
          .connect(targetWallet)
          .distribute(
            ...getStakingEscrowDistributeArguments(
              await getSignedDistribution(
                await escrow.getAddress(),
                '00000000-0000-0000-0000-000000000000',
                owner,
                targetWallet.address,
                await usdc.getAddress(),
                quantity,
              ),
            ),
          ),
      ).to.eventually.be.rejectedWith(/invalidated nonce/i);
    });

    it('should fail for invalid nonce timestamp', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const quantity = BigInt(10000000);

      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );
      await usdc.transfer(await escrow.getAddress(), quantity);

      const signedDistribution1 = await getSignedDistribution(
        await escrow.getAddress(),
        '00000000-0000-0000-0000-000000000000',
        owner,
        targetWallet.address,
        await usdc.getAddress(),
        quantity,
        uuidv1({ msecs: Date.now() + 10000 }),
      );
      await escrow
        .connect(targetWallet)
        .distribute(
          ...getStakingEscrowDistributeArguments(signedDistribution1),
        );

      await expect(
        escrow
          .connect(targetWallet)
          .distribute(
            ...getStakingEscrowDistributeArguments(
              await getSignedDistribution(
                await escrow.getAddress(),
                signedDistribution1.nonce,
                owner,
                targetWallet.address,
                await usdc.getAddress(),
                quantity,
                uuidv1({ msecs: Date.now() - 10000 }),
              ),
            ),
          ),
      ).to.eventually.be.rejectedWith(
        /nonce timestamp must be later than parent/i,
      );
    });

    it('should fail for invalid token address', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const quantity = BigInt(10000000);

      const wrongToken = await (
        await (await ethers.getContractFactory('USDC')).connect(owner).deploy()
      ).waitForDeployment();
      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );
      await usdc.transfer(await escrow.getAddress(), quantity);

      await expect(
        escrow
          .connect(targetWallet)
          .distribute(
            ...getStakingEscrowDistributeArguments(
              await getSignedDistribution(
                await escrow.getAddress(),
                '00000000-0000-0000-0000-000000000000',
                owner,
                targetWallet.address,
                await wrongToken.getAddress(),
                quantity,
              ),
            ),
          ),
      ).to.eventually.be.rejectedWith(/invalid asset address/i);
    });

    it('should fail for invalid exchangeSignature', async () => {
      const targetWallet = (await ethers.getSigners())[1];
      const wrongExchangeWallet = (await ethers.getSigners())[2];
      const quantity = BigInt(10000000);

      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );
      await usdc.transfer(await escrow.getAddress(), quantity);

      await expect(
        escrow
          .connect(targetWallet)
          .distribute(
            ...getStakingEscrowDistributeArguments(
              await getSignedDistribution(
                await escrow.getAddress(),
                '00000000-0000-0000-0000-000000000000',
                wrongExchangeWallet,
                targetWallet.address,
                await usdc.getAddress(),
                quantity,
              ),
            ),
          ),
      ).to.eventually.be.rejectedWith(/invalid exchange signature/i);
    });
  });

  describe('withdrawEscrow', () => {
    it('should work with native asset', async () => {
      const quantity = BigInt(10000000);

      const escrow = await EarningsEscrowFactory.deploy(
        ethers.ZeroAddress,
        owner,
      );
      await owner.sendTransaction({
        to: await escrow.getAddress(),
        value: quantity,
      });

      await escrow.withdrawEscrow(quantity);

      const events = await escrow.queryFilter(escrow.filters.EscrowWithdrawn());
      expect(events).to.be.an('array');
      expect(events).to.have.lengthOf(1);
      expect(events[0].args?.quantity).to.equal(quantity);
      expect(events[0].args?.newEscrowBalance).to.equal('0');
    });

    it('should work with token', async () => {
      const quantity = BigInt(10000000);

      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );
      await usdc.transfer(await escrow.getAddress(), quantity);

      await escrow.withdrawEscrow(quantity);

      const events = await escrow.queryFilter(escrow.filters.EscrowWithdrawn());
      expect(events).to.be.an('array');
      expect(events).to.have.lengthOf(1);
      expect(events[0].args?.quantity).to.equal(quantity);
      expect(events[0].args?.newEscrowBalance).to.equal('0');
    });

    it('should fail for non-admin caller', async () => {
      const quantity = BigInt(10000000);

      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );
      await usdc.transfer(await escrow.getAddress(), quantity);

      await expect(
        escrow.connect((await ethers.getSigners())[1]).withdrawEscrow(quantity),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });

  describe('loadLastNonce', async () => {
    it('should work for valid address', async () => {
      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );

      const lastNonce = (
        await escrow.loadLastNonce((await ethers.getSigners())[1])
      ).toString();
      expect(lastNonce).to.equal('0');
    });

    it('should revert for empty address', async () => {
      const escrow = await EarningsEscrowFactory.deploy(
        await usdc.getAddress(),
        owner,
      );

      await expect(
        escrow.loadLastNonce(ethers.ZeroAddress),
      ).to.eventually.be.rejectedWith(/invalid wallet address/i);
    });
  });
});

async function getSignedDistribution(
  escrowAddress: string,
  parentNonce: string,
  exchangeWallet: SignerWithAddress,
  targetWallet: string,
  assetAddress: string,
  quantity: bigint,
  nonce?: string,
): Promise<SignedAssetDistribution> {
  const distribution = {
    nonce: nonce || uuidv1(),
    parentNonce,
    walletAddress: targetWallet,
    assetAddress,
    quantity,
  };
  return {
    ...distribution,
    exchangeSignature: await exchangeWallet.signMessage(
      ethers.getBytes(getStakingDistributionHash(escrowAddress, distribution)),
    ),
  };
}
