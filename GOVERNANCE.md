# Controls and Governance

## Overview

Ikon’s on-chain components span three primary contracts, each with attendant controls and governance. Ikon’s primary contracts also interact with an extensible set of bridge adapter contracts.

## Custodian Contract

The Custodian contract custodies user funds with minimal additional logic. Specifically, it tracks two control contract addresses:

- Exchange: the Exchange contract address is the only agent whitelisted to authorize transfers of funds out of the Custodian.
- Governance: the Governance contract address is the only agent whitelisted to authorize changing the Exchange and Governance contract addresses within the Custodian.

The Custodian has no control logic itself beyond the above authorizations. Its logic is limited by design to maximize future upgradability without requiring fund migration.

## Governance Contract

The Governance contract implements the contract upgrade logic while enforcing governance constraints.

- The Governance contract has a single owner, and the owner can be changed with no delay by the owner.
- The Governance contract has a single admin, and the admin can be changed with no delay by the owner.
- The admin is the only agent whitelisted to change the Custodian’s Exchange or Governance contract addresses, but the change is a two-step process.
  - The admin first calls an upgrade authorization with the new contract address, which initiates the Contract Upgrade Period.
  - Once the Contract Upgrade Period expires, the admin can make a second call that completes the change to the new contract address.
- At any time during the Contract Upgrade Period, the admin can cancel the upgrade immediately.

The Governance contract also implements field update logic for sensitive Exchange settings.

- The admin is the only agent whitelisted to change several Exchange settings:
  - Bridge adapter contract address whitelist
  - Index price service wallet address whitelist
  - Insurance fund wallet address, provided that neither the existing nor new wallet has any open non-quote positions
  - Market configuration override values, subject to limits as defined in Exchange contract’s [fixed parameter settings](#market-override-fixed-parameter-settings).
- Updating any of the governed fields is a two-step process.
  - The admin first calls an update initiation with the new value(s), which initiates the Field  Update Period.
  - Once the Field Update Period expires, the admin or the dispatcher wallet can make a second call that completes the change to the setting. The dispatcher wallet is authorized to finalize an update in order to synchronize configuration changes between on-chain and off-chain systems.
- At any time during the Field Update Period, the admin can cancel the update immediately.

### Fixed Parameter Settings

These settings have been pre-determined and may be hard-coded or implicit in the contract logic.

- Owner Change Period: immediate
- Admin Change Period: immediate
- Contract Upgrade Period: 72 hours, set during deployment
- Contract Upgrade Cancellation Period: immediate
- Field Update Period: 24 hours
- Field Update Cancellation Period: immediate

## Exchange Contract

The Exchange contract implements the majority of exchange functionality, including wallet asset balance tracking. As such, it contains several fine-grained control and protection mechanisms:

- Exchange has a single owner, and the owner can be changed with no delay by the owner.
- Exchange has a single admin, and the admin can be changed with no delay by the owner.
- The admin can change the Chain Propagation Period with no delay, subject to the Minimum Chain Propagation Period and Maximum Chain Propagation Period limits.
- The admin can change the Delegated Key Expiration Period with no delay, subject to the Minimum Delegated Key Expiration Period and Maximum Delegated Key Expiration Period limits.
- The admin can change the Position Below Minimum Liquidation Price Tolerance Multiplier with no delay to a non-negative value less than or equal to the Maximum Fee Rate.
- Exchange tracks a single exit fund wallet address, and the exit fund wallet can be changed with no delay by the admin, provided that neither the existing nor new wallet has any open positions or quote balance.
- The admin can withdraw any positive quote balance from the exit fund after a fixed delay after the exit fund opens its first non-quote position.
- Exchange tracks a single fee wallet address, and the fee wallet can be changed with no delay by the admin.
- The admin can change or remove an addresses as the dispatcher wallet with no delay. The dispatcher wallet is authorized to call operator-only contract functions: `executeTrade`, `liquidatePositionBelowMinimum`, `liquidatePositionInDeactivatedMarket`, `liquidateWalletInMaintenance`, `liquidateWalletInMaintenanceDuringSystemRecovery`, `liquidateWalletExited`, `deleverageInMaintenanceAcquisition`, `deleverageInsuranceFundClosure`, `deleverageExitAcquisition`, `deleverageExitFundClosure`, `transfer`, `withdraw`, `activateMarket`, `deactivateMarket`, `publishIndexPrices`, and `publishFundingMultiplier`.
- The admin can add new markets with no delay, with new market fields subject to limits. The dispatcher wallet can activate and deactivate markets.
- The admin can skim any tokens mistakenly sent to the Exchange contract rather than deposited.
- Wallet exits are user-initiated, and 1) prevent the target wallet from deposits, trades, normal withdrawals, and transfers and 2) subsequently allow the user to close all open positions and withdraw any positive quote balance.
  - User calls `exitWallet` on Exchange.
  - Exchange records the exit and block number, immediately blocks deposits, and starts the Chain Propagation Period.
  - After the Chain Propagation Period expires:
    - Exchange blocks any trades, normal withdrawals, and transfers for the wallet.
    - Exchange allows the user to close all open positions at the exit price and withdraw any positive quote balance via `withdrawExit`.
  - Off-chain, on detecting the `WalletExited` event:
    - All core actions are disabled for the wallet.
    - The wallet is marked as exited, which prevents re-enabling any of the core actions.
    - All open orders are canceled for the wallet.
    - The dispatcher wallet calls `liquidateWalletExited` or `deleverageExitAcquisition`, proactively closing all open positions of the wallet at the exit price.
  - An exited wallet can be reinstated for trading by calling the `clearWalletExit` function on Exchange.
- Nonce invalidation is user-initiated rather than operator-initiated.
  - User calls `invalidateOrderNonce` on Exchange with a nonce before which all orders and delegated keys should be invalidated.
    - Exchange validates:
      - The new nonce is not more than one day in the future.
      - The new nonce is newer than the last invalidated nonce, if present.
      - The current block is at or greater than the last invalidation's effective block number, if present.
    - Exchange records the invalidation, and starts enforcing it in the trade function after the Chain Propagation Period.
  - Off-chain, on detecting the `OrderNonceInvalidated` event:
    - All orders opened prior to the target nonce for the wallet are canceled.
    - All delegated keys authorized prior to the target nonce are revoked.
- Fee maximums are enforced by Exchange and specified by the Maximum Fee Rate, which cannot be changed. The Maximum Fee Rate applies to both maker and taker trade fees, position in deactivated market liquidation, withdrawals and transfers.

### Fixed Parameter Settings

These settings have been pre-determined and may be hard-coded or implicit in the contract logic.

- Owner Change Period: immediate
- Admin Change Period: immediate
- Minimum Chain Propagation Period: 0
- Maximum Chain Propagation Period: 1 week
- Chain Propagation Change Period: immediate
- Minimum Delegated Key Expiration Period: 0
- Maximum Delegated Key Expiration Period: 1 year
- Delegated Key Expiration Change Period: immediate
- Exit Fund Wallet Change Period: immediate
- Exit Fund Withdraw Delay: 1 week
- Fee Wallet Change Period: immediate
- Dispatcher Wallet Change Period: immediate
- Market Override Field Limits <a id="market-override-fixed-parameter-settings"></a>
  - Minimum Initial Margin Fraction: 0.005
  - Minimum Maintenance Margin Fraction: 0.003
  - Minimum Incremental Initial Margin Fraction: 0.001
  - Maximum Baseline Position Size: 2^63 - 1
  - Incremental Position Size: > 0
  - Maximum Maximum Position Size: 2^63 - 1
  - Maximum Minimum Position Size: 2^63 - 2
- Maximum Fee Rate: 20%

### Changeable Parameters

These settings have the initial values below but are changeable in the contract according to the above specs.

- Chain Propagation Period: 1 hour
- Delegated Key Expiration Period: 35 days

## Bridge Adapter Contracts

The Exchange contract integrates with an extensible set of bridge adapter contracts (BACs). BACs contain the necessary logic to support seamless cross-chain deposits and withdrawal via bridge protocols.

- A whitelist defines the supported BAC addresses, and the admin can update the whitelist according to [Governance’s](#governance-contract) field update logic.
- BACs have a single owner, and the owner can be changed with no delay by the owner.
- BACs have a single admin, and the admin can be changed with no delay by the owner.
- BACs implement controls for enabling and disabling deposits and withdrawals, and the admin can change either setting with no delay.
- The admin can skim any tokens mistakenly sent to a BAC contract. By design, protocols settle deposits and withdrawals in a single transaction.
- The admin can withdraw the native asset, used by some protocols for additional fee settlement, with no delay.
- Some BACs implement a configurable slippage multiplier, which the admin can change to any non-negative value with no delay.

### Fixed Parameter Settings

These settings have been pre-determined and may be hard-coded or implicit in the contract logic.

- Owner Change Period: immediate
- Admin Change Period: immediate
- Deposit Change Period: immediate
- Withdrawal Change Period: immediate
- Slippage Change Period: immediate.
