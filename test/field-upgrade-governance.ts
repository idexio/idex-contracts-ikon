import { ethers } from 'hardhat';
import { expect } from 'chai';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import { baseAssetSymbol, deployAndAssociateContracts } from './helpers';
import type {
  Custodian,
  Exchange_v4,
  ExchangeStargateAdapter,
  ExchangeStargateAdapter__factory,
  Governance,
  USDC,
} from '../typechain-types';

describe('Governance', function () {
  let custodian: Custodian;
  let exchange: Exchange_v4;
  let governance: Governance;
  let ownerWallet: SignerWithAddress;
  let usdc: USDC;

  beforeEach(async () => {
    const wallets = await ethers.getSigners();
    ownerWallet = wallets[0];
    const [
      ,
      dispatcherWallet,
      exitFundWallet,
      feeWallet,
      indexPriceServiceWallet,
      insuranceFundWallet,
    ] = wallets;

    const results = await deployAndAssociateContracts(
      ownerWallet,
      dispatcherWallet,
      exitFundWallet,
      feeWallet,
      indexPriceServiceWallet,
      insuranceFundWallet,
    );

    custodian = results.custodian;
    exchange = results.exchange;
    governance = results.governance;
    usdc = results.usdc;
  });

  describe('bridge adapters upgrade', () => {
    let bridgeAdapter: ExchangeStargateAdapter;
    let ExchangeStargateAdapterFactory: ExchangeStargateAdapter__factory;

    beforeEach(async () => {
      ExchangeStargateAdapterFactory = await ethers.getContractFactory(
        'ExchangeStargateAdapter',
      );

      bridgeAdapter = await ExchangeStargateAdapterFactory.deploy(
        custodian.address,
        99900000,
        exchange.address,
        usdc.address,
      );
    });

    describe('initiateBridgeAdaptersUpgrade', () => {
      it('should work for valid contract address', async () => {
        await governance.initiateBridgeAdaptersUpgrade([bridgeAdapter.address]);
        expect(
          governance.queryFilter(
            governance.filters.BridgeAdaptersUpgradeInitiated(),
          ),
        )
          .to.eventually.be.an('array')
          .with.lengthOf(1);
      });

      it('should revert for invalid address', async () => {
        await expect(
          governance.initiateBridgeAdaptersUpgrade([
            (await ethers.getSigners())[0].address,
          ]),
        ).to.eventually.be.rejectedWith(/invalid adapter address/i);
      });

      it('should revert when already in progress', async () => {
        await governance.initiateBridgeAdaptersUpgrade([bridgeAdapter.address]);

        await expect(
          governance.initiateBridgeAdaptersUpgrade([bridgeAdapter.address]),
        ).to.eventually.be.rejectedWith(/already in progress/i);
      });

      it('should revert when not called by admin', async () => {
        await expect(
          governance
            .connect((await ethers.getSigners())[5])
            .initiateBridgeAdaptersUpgrade([bridgeAdapter.address]),
        ).to.eventually.be.rejectedWith(/caller must be admin wallet/i);
      });
    });

    describe('cancelBridgeAdaptersUpgrade', () => {
      it('should work when in progress', async () => {
        await governance.initiateBridgeAdaptersUpgrade([bridgeAdapter.address]);
        await governance.cancelBridgeAdaptersUpgrade();
        expect(
          governance.queryFilter(
            governance.filters.BridgeAdaptersUpgradeCanceled(),
          ),
        )
          .to.eventually.be.an('array')
          .with.lengthOf(1);
      });

      it('should revert when not in progress', async () => {
        await expect(
          governance.cancelBridgeAdaptersUpgrade(),
        ).to.eventually.be.rejectedWith(/no adapter upgrade in progress/i);
      });

      it('should revert when not called by admin', async () => {
        await expect(
          governance
            .connect((await ethers.getSigners())[5])
            .cancelBridgeAdaptersUpgrade(),
        ).to.eventually.be.rejectedWith(/caller must be admin wallet/i);
      });
    });

    describe('finalizeBridgeAdaptersUpgrade', async () => {
      it('should work after block delay when upgrade was initiated', async () => {
        await governance.initiateBridgeAdaptersUpgrade([bridgeAdapter.address]);

        await mine((1 * 24 * 60 * 60) / 3, { interval: 0 });

        await governance.finalizeBridgeAdaptersUpgrade([bridgeAdapter.address]);
        expect(
          governance.queryFilter(
            governance.filters.BridgeAdaptersUpgradeFinalized(),
          ),
        )
          .to.eventually.be.an('array')
          .with.lengthOf(1);
      });

      it('should revert when not in progress', async () => {
        await expect(
          governance.finalizeBridgeAdaptersUpgrade([bridgeAdapter.address]),
        ).to.eventually.be.rejectedWith(/no adapter upgrade in progress/i);
      });

      it('should revert before block delay', async () => {
        await governance.initiateBridgeAdaptersUpgrade([bridgeAdapter.address]);

        await expect(
          governance.finalizeBridgeAdaptersUpgrade([bridgeAdapter.address]),
        ).to.eventually.be.rejectedWith(/Block threshold not yet reached/i);
      });

      it('should revert on address length mismatch', async () => {
        await governance.initiateBridgeAdaptersUpgrade([bridgeAdapter.address]);

        await mine((1 * 24 * 60 * 60) / 3, { interval: 0 });

        await expect(
          governance.finalizeBridgeAdaptersUpgrade([
            bridgeAdapter.address,
            ownerWallet.address,
          ]),
        ).to.eventually.be.rejectedWith(/address mismatch/i);
      });

      it('should revert on address  mismatch', async () => {
        await governance.initiateBridgeAdaptersUpgrade([bridgeAdapter.address]);

        await mine((1 * 24 * 60 * 60) / 3, { interval: 0 });

        await expect(
          governance.finalizeBridgeAdaptersUpgrade([ownerWallet.address]),
        ).to.eventually.be.rejectedWith(/address mismatch/i);
      });
    });

    describe('IPS wallet upgrade', () => {
      let newIndexPriceServiceWallets: string[];
      beforeEach(async () => {
        newIndexPriceServiceWallets = [(await ethers.getSigners())[10].address];
      });

      describe('initiateIndexPriceServiceWalletsUpgrade', () => {
        it('should work for valid wallet address', async () => {
          await governance.initiateIndexPriceServiceWalletsUpgrade(
            newIndexPriceServiceWallets,
          );
          expect(
            governance.queryFilter(
              governance.filters.IndexPriceServiceWalletsUpgradeInitiated(),
            ),
          )
            .to.eventually.be.an('array')
            .with.lengthOf(1);
        });

        it('should revert for invalid address', async () => {
          await expect(
            governance.initiateIndexPriceServiceWalletsUpgrade([
              ethers.constants.AddressZero,
            ]),
          ).to.eventually.be.rejectedWith(/invalid IPS wallet address/i);
        });

        it('should revert when already in progress', async () => {
          await governance.initiateIndexPriceServiceWalletsUpgrade(
            newIndexPriceServiceWallets,
          );

          await expect(
            governance.initiateIndexPriceServiceWalletsUpgrade(
              newIndexPriceServiceWallets,
            ),
          ).to.eventually.be.rejectedWith(/already in progress/i);
        });

        it('should revert when not called by admin', async () => {
          await expect(
            governance
              .connect((await ethers.getSigners())[5])
              .initiateIndexPriceServiceWalletsUpgrade(
                newIndexPriceServiceWallets,
              ),
          ).to.eventually.be.rejectedWith(/caller must be admin wallet/i);
        });
      });

      describe('cancelIndexPriceServiceWalletsUpgrade', () => {
        it('should work when in progress', async () => {
          await governance.initiateIndexPriceServiceWalletsUpgrade(
            newIndexPriceServiceWallets,
          );
          await governance.cancelIndexPriceServiceWalletsUpgrade();
          expect(
            governance.queryFilter(
              governance.filters.IndexPriceServiceWalletsUpgradeCanceled(),
            ),
          )
            .to.eventually.be.an('array')
            .with.lengthOf(1);
        });

        it('should revert when not in progress', async () => {
          await expect(
            governance.cancelIndexPriceServiceWalletsUpgrade(),
          ).to.eventually.be.rejectedWith(/no IPS wallet upgrade in progress/i);
        });

        it('should revert when not called by admin', async () => {
          await expect(
            governance
              .connect((await ethers.getSigners())[5])
              .cancelIndexPriceServiceWalletsUpgrade(),
          ).to.eventually.be.rejectedWith(/caller must be admin wallet/i);
        });
      });

      describe('finalizeIndexPriceServiceWalletsUpgrade', async () => {
        it('should work when in progress', async () => {
          await governance.initiateIndexPriceServiceWalletsUpgrade(
            newIndexPriceServiceWallets,
          );

          await mine((1 * 24 * 60 * 60) / 3, { interval: 0 });

          await governance.finalizeIndexPriceServiceWalletsUpgrade(
            newIndexPriceServiceWallets,
          );
          expect(
            governance.queryFilter(
              governance.filters.IndexPriceServiceWalletsUpgradeFinalized(),
            ),
          )
            .to.eventually.be.an('array')
            .with.lengthOf(1);
        });

        it('should revert when not in progress', async () => {
          await expect(
            governance.finalizeIndexPriceServiceWalletsUpgrade(
              newIndexPriceServiceWallets,
            ),
          ).to.eventually.be.rejectedWith(/no IPS wallet upgrade in progress/i);
        });

        it('should revert before block delay', async () => {
          await governance.initiateIndexPriceServiceWalletsUpgrade(
            newIndexPriceServiceWallets,
          );

          await expect(
            governance.finalizeIndexPriceServiceWalletsUpgrade(
              newIndexPriceServiceWallets,
            ),
          ).to.eventually.be.rejectedWith(/Block threshold not yet reached/i);
        });

        it('should revert on address length mismatch', async () => {
          await governance.initiateIndexPriceServiceWalletsUpgrade(
            newIndexPriceServiceWallets,
          );

          await mine((1 * 24 * 60 * 60) / 3, { interval: 0 });

          await expect(
            governance.finalizeIndexPriceServiceWalletsUpgrade([
              ...newIndexPriceServiceWallets,
              ...newIndexPriceServiceWallets,
            ]),
          ).to.eventually.be.rejectedWith(/address mismatch/i);
        });

        it('should revert on address  mismatch', async () => {
          await governance.initiateIndexPriceServiceWalletsUpgrade(
            newIndexPriceServiceWallets,
          );

          await mine((1 * 24 * 60 * 60) / 3, { interval: 0 });

          await expect(
            governance.finalizeIndexPriceServiceWalletsUpgrade([
              ownerWallet.address,
            ]),
          ).to.eventually.be.rejectedWith(/address mismatch/i);
        });
      });
    });
  });

  describe('IF wallet upgrade', () => {
    describe('initiateInsuranceFundWalletUpgrade', () => {
      let newInsuranceFundWallet: SignerWithAddress;

      beforeEach(async () => {
        [newInsuranceFundWallet] = await ethers.getSigners();
      });

      it('should work for valid wallet address', async () => {
        await governance.initiateInsuranceFundWalletUpgrade(
          newInsuranceFundWallet.address,
        );

        expect(
          governance.queryFilter(
            governance.filters.InsuranceFundWalletUpgradeInitiated(),
          ),
        )
          .to.eventually.be.an('array')
          .with.lengthOf(1);
      });

      it('should revert for zero address', async () => {
        await expect(
          governance.initiateInsuranceFundWalletUpgrade(
            ethers.constants.AddressZero,
          ),
        ).to.eventually.be.rejectedWith(/invalid IF wallet address/i);
      });

      it('should revert when upgrade already in progress', async () => {
        await governance.initiateInsuranceFundWalletUpgrade(
          newInsuranceFundWallet.address,
        );
        await expect(
          governance.initiateInsuranceFundWalletUpgrade(
            newInsuranceFundWallet.address,
          ),
        ).to.eventually.be.rejectedWith(/upgrade already in progress/i);
      });

      it('should revert when not called by admin', async () => {
        await expect(
          governance
            .connect((await ethers.getSigners())[1])
            .initiateInsuranceFundWalletUpgrade(newInsuranceFundWallet.address),
        ).to.eventually.be.rejectedWith(/caller must be admin/i);
      });
    });

    describe('cancelInsuranceFundWalletUpgrade', () => {
      let newInsuranceFundWallet: SignerWithAddress;

      beforeEach(async () => {
        [newInsuranceFundWallet] = await ethers.getSigners();
      });

      it('should work when in progress', async () => {
        await governance.initiateInsuranceFundWalletUpgrade(
          newInsuranceFundWallet.address,
        );
        await governance.cancelInsuranceFundWalletUpgrade();
        expect(
          governance.queryFilter(
            governance.filters.InsuranceFundWalletUpgradeCanceled(),
          ),
        )
          .to.eventually.be.an('array')
          .with.lengthOf(1);
      });

      it('should revert when not in progress', async () => {
        await expect(
          governance.cancelInsuranceFundWalletUpgrade(),
        ).to.eventually.be.rejectedWith(/no IF wallet upgrade in progress/i);
      });

      it('should revert when not called by admin', async () => {
        await expect(
          governance
            .connect((await ethers.getSigners())[5])
            .cancelInsuranceFundWalletUpgrade(),
        ).to.eventually.be.rejectedWith(/caller must be admin wallet/i);
      });
    });

    describe('finalizeInsuranceFundWalletUpgrade', () => {
      let newInsuranceFundWallet: SignerWithAddress;

      before(async () => {
        newInsuranceFundWallet = (await ethers.getSigners())[10];
      });

      it('should work after block delay when upgrade was initiated', async () => {
        await governance.initiateInsuranceFundWalletUpgrade(
          newInsuranceFundWallet.address,
        );

        await mine((2 * 24 * 60 * 60) / 3, { interval: 0 });

        await governance.finalizeInsuranceFundWalletUpgrade(
          newInsuranceFundWallet.address,
        );

        await expect(exchange.insuranceFundWallet()).to.eventually.equal(
          newInsuranceFundWallet.address,
        );
        expect(
          governance.queryFilter(
            governance.filters.InsuranceFundWalletUpgradeFinalized(),
          ),
        )
          .to.eventually.be.an('array')
          .with.lengthOf(1);
      });

      it('should revert when not in progress', async () => {
        await expect(
          governance.finalizeInsuranceFundWalletUpgrade(
            newInsuranceFundWallet.address,
          ),
        ).to.eventually.be.rejectedWith(/no IF wallet upgrade in progress/i);
      });

      it('should revert on address  mismatch', async () => {
        await governance.initiateInsuranceFundWalletUpgrade(
          newInsuranceFundWallet.address,
        );

        await mine((1 * 24 * 60 * 60) / 3, { interval: 0 });

        await expect(
          governance.finalizeInsuranceFundWalletUpgrade(ownerWallet.address),
        ).to.eventually.be.rejectedWith(/address mismatch/i);
      });

      it('should revert before block delay', async () => {
        await governance.initiateInsuranceFundWalletUpgrade(
          newInsuranceFundWallet.address,
        );

        await expect(
          governance.finalizeInsuranceFundWalletUpgrade(
            newInsuranceFundWallet.address,
          ),
        ).to.eventually.be.rejectedWith(/Block threshold not yet reached/i);
      });
    });
  });

  describe('market overrides upgrade', () => {
    const marketOverrides = {
      initialMarginFraction: '3000000',
      maintenanceMarginFraction: '1000000',
      incrementalInitialMarginFraction: '1000000',
      baselinePositionSize: '14000000000',
      incrementalPositionSize: '2800000000',
      maximumPositionSize: '1000000000000',
      minimumPositionSize: '10000000',
    };
    let walletToOverride: string;

    before(async () => {
      walletToOverride = (await ethers.getSigners())[10].address;
    });

    describe('initiateMarketOverridesUpgrade', () => {
      it('should work for valid wallet address', async () => {
        await governance.initiateMarketOverridesUpgrade(
          baseAssetSymbol,
          marketOverrides,
          walletToOverride,
        );

        expect(
          governance.queryFilter(
            governance.filters.MarketOverridesUpgradeInitiated(),
          ),
        )
          .to.eventually.be.an('array')
          .with.lengthOf(1);
      });

      it('should revert when upgrade already in progress', async () => {
        await governance.initiateMarketOverridesUpgrade(
          baseAssetSymbol,
          marketOverrides,
          walletToOverride,
        );

        await expect(
          governance.initiateMarketOverridesUpgrade(
            baseAssetSymbol,
            marketOverrides,
            walletToOverride,
          ),
        ).to.eventually.be.rejectedWith(/upgrade already in progress/i);
      });

      it('should revert when not called by admin', async () => {
        await expect(
          governance
            .connect((await ethers.getSigners())[1])
            .initiateMarketOverridesUpgrade(
              baseAssetSymbol,
              marketOverrides,
              walletToOverride,
            ),
        ).to.eventually.be.rejectedWith(/caller must be admin/i);
      });
    });

    describe('cancelMarketOverridesUpgrade', () => {
      it('should work when in progress', async () => {
        await governance.initiateMarketOverridesUpgrade(
          baseAssetSymbol,
          marketOverrides,
          walletToOverride,
        );
        await governance.cancelMarketOverridesUpgrade(
          baseAssetSymbol,
          walletToOverride,
        );
        expect(
          governance.queryFilter(
            governance.filters.MarketOverridesUpgradeCanceled(),
          ),
        )
          .to.eventually.be.an('array')
          .with.lengthOf(1);
      });

      it('should revert when not in progress', async () => {
        await expect(
          governance.cancelMarketOverridesUpgrade(
            baseAssetSymbol,
            walletToOverride,
          ),
        ).to.eventually.be.rejectedWith(
          /no market override upgrade in progress/i,
        );
      });
    });

    describe('finalizeMarketOverridesUpgrade', () => {
      it('should work after block delay when upgrade was initiated', async () => {
        await governance.initiateMarketOverridesUpgrade(
          baseAssetSymbol,
          marketOverrides,
          walletToOverride,
        );

        await mine((1 * 24 * 60 * 60) / 3, { interval: 0 });

        await governance.finalizeMarketOverridesUpgrade(
          baseAssetSymbol,
          marketOverrides,
          walletToOverride,
        );

        expect(
          governance.queryFilter(
            governance.filters.MarketOverridesUpgradeFinalized(),
          ),
        )
          .to.eventually.be.an('array')
          .with.lengthOf(1);
      });

      it('should revert when not in progress', async () => {
        await expect(
          governance.finalizeMarketOverridesUpgrade(
            baseAssetSymbol,
            marketOverrides,
            walletToOverride,
          ),
        ).to.eventually.be.rejectedWith(
          /no market override upgrade in progress for wallet/i,
        );
      });

      it('should revert before block delay', async () => {
        await governance.initiateMarketOverridesUpgrade(
          baseAssetSymbol,
          marketOverrides,
          walletToOverride,
        );

        await expect(
          governance.finalizeMarketOverridesUpgrade(
            baseAssetSymbol,
            marketOverrides,
            walletToOverride,
          ),
        ).to.eventually.be.rejectedWith(/Block threshold not yet reached/i);
      });

      it('should revert on field mismatch', async () => {
        await governance.initiateMarketOverridesUpgrade(
          baseAssetSymbol,
          marketOverrides,
          walletToOverride,
        );

        await mine((1 * 24 * 60 * 60) / 3, { interval: 0 });

        await expect(
          governance.finalizeMarketOverridesUpgrade(
            baseAssetSymbol,
            { ...marketOverrides, initialMarginFraction: '5000000' },
            walletToOverride,
          ),
        ).to.eventually.be.rejectedWith(/overrides mismatch/i);
      });
    });
  });
});
