# ranked_findings — exploitability ranking (Phase 1)

Input: 447 pattern findings from `opencode_artifacts/run3`; ranked 447, skipped 0.

## Bucket distribution

| bucket | count |
|--------|-------|
| HIGH | 178 |
| MEDIUM | 205 |
| LOW | 64 |

## By detector (count, min–max score)

| detector | count | score range |
|----------|-------|-------------|
| ZeroAddress | 129 | 4–11 |
| IntegerOverflow | 69 | 4–10 |
| Reentrancy | 49 | 2–12 |
| Timestamp | 49 | 3–11 |
| FrontRunning | 28 | 6–12 |
| StorageCollision | 24 | 1–1 |
| AccessControl | 23 | 8–14 |
| MEV | 21 | 6–12 |
| ValueFlow | 16 | 8–12 |
| OracleManipulation | 15 | 5–12 |
| OracleTaint | 9 | 5–11 |
| Uninitialized | 9 | 1–1 |
| SignatureReplay | 3 | 8–8 |
| CrossChain | 1 | 10–10 |
| BadRandomness | 1 | 6–6 |
| UncheckedCall | 1 | 6–6 |

## Top 15

1. **HIGH** score=14 `morpho-blue` `AccessControl` `HIGH` `Morpho.sol:347` `liquidate` — Function 'liquidate' performs a privileged operation but lacks access control (no auth modifier or msg.sender/tx.origin check).
   signals: taint_reaches_flag, user_controlled_call_target, value_to_user, no_access_control, no_reentrancy_guard
2. **HIGH** score=12 `compound-v3` `OracleManipulation` `HIGH` `CometWithExtendedAssetList.sol:345` `getPrice` — Chainlink oracle read detected without staleness/round validation. Validate updatedAt/answeredInRound before using the price.
   signals: taint_reaches_flag, user_controlled_call_target, no_access_control, no_reentrancy_guard
3. **HIGH** score=12 `grace` `AccessControl` `HIGH` `Pool.sol:313` `withdraw` — Function 'withdraw' performs a privileged operation but lacks access control (no auth modifier or msg.sender/tx.origin check).
   signals: taint_reaches_flag, value_to_user, no_access_control, no_reentrancy_guard
4. **HIGH** score=12 `grace` `AccessControl` `HIGH` `Pool.sol:349` `redeem` — Function 'redeem' performs a privileged operation but lacks access control (no auth modifier or msg.sender/tx.origin check).
   signals: taint_reaches_flag, value_to_user, no_access_control, no_reentrancy_guard
5. **HIGH** score=12 `monolith-market` `AccessControl` `HIGH` `ERC4626.sol:73` `withdraw` — Function 'withdraw' performs a privileged operation but lacks access control (no auth modifier or msg.sender/tx.origin check).
   signals: taint_reaches_flag, value_to_user, no_access_control, no_reentrancy_guard
6. **HIGH** score=12 `monolith-market` `AccessControl` `HIGH` `ERC4626.sol:95` `redeem` — Function 'redeem' performs a privileged operation but lacks access control (no auth modifier or msg.sender/tx.origin check).
   signals: taint_reaches_flag, value_to_user, no_access_control, no_reentrancy_guard
7. **HIGH** score=12 `monolith-market` `Reentrancy` `HIGH` `Lender.sol:286` `liquidate` — Potential reentrancy: external call is followed by a state modification (checks-effects-interactions violation).
   signals: taint_reaches_flag, value_to_user, no_access_control, no_reentrancy_guard
8. **HIGH** score=12 `monolith-market` `AccessControl` `HIGH` `Lender.sol:260` `liquidate` — Function 'liquidate' performs a privileged operation but lacks access control (no auth modifier or msg.sender/tx.origin check).
   signals: taint_reaches_flag, value_to_user, no_access_control, no_reentrancy_guard
9. **HIGH** score=12 `monolith-market` `Reentrancy` `HIGH` `Lender.sol:326` `writeOff` — Potential reentrancy: external call is followed by a state modification (checks-effects-interactions violation).
   signals: taint_reaches_flag, value_to_user, no_access_control, no_reentrancy_guard
10. **HIGH** score=12 `monolith-market` `Reentrancy` `HIGH` `Lender.sol:347` `redeem` — Potential reentrancy: external call is followed by a state modification (checks-effects-interactions violation).
   signals: taint_reaches_flag, value_to_user, no_access_control, no_reentrancy_guard
11. **HIGH** score=12 `monolith-market` `AccessControl` `HIGH` `Lender.sol:339` `redeem` — Function 'redeem' performs a privileged operation but lacks access control (no auth modifier or msg.sender/tx.origin check).
   signals: taint_reaches_flag, value_to_user, no_access_control, no_reentrancy_guard
12. **HIGH** score=12 `morpho-blue` `ValueFlow` `HIGH` `Morpho.sol:183` `supply` — The amount requested in the token transfer ('assets') is credited to 'shares' without verifying the balance actually received. A fee-on-transfer or rebasing token (or an address chosen by the caller) makes the recorded credit diverge from real holdings, letting a counterparty over-credit and redirect funds; read balanceOf(address(this)) deltas instead.
   signals: taint_reaches_flag, user_controlled_call_target, no_access_control, no_reentrancy_guard
13. **HIGH** score=12 `morpho-blue` `ValueFlow` `HIGH` `Morpho.sol:283` `repay` — The amount requested in the token transfer ('assets') is credited to 'shares' without verifying the balance actually received. A fee-on-transfer or rebasing token (or an address chosen by the caller) makes the recorded credit diverge from real holdings, letting a counterparty over-credit and redirect funds; read balanceOf(address(this)) deltas instead.
   signals: taint_reaches_flag, user_controlled_call_target, no_access_control, no_reentrancy_guard
14. **HIGH** score=12 `vaultlayer` `FrontRunning` `MEDIUM` `NFTLendMarket.sol:517` `claimDefaultedLoan` — Function 'claimDefaultedLoan' moves funds or uses price data without slippage/deadline protection; may be vulnerable to front-running.
   signals: taint_reaches_flag, user_controlled_call_target, value_to_user, no_access_control
15. **HIGH** score=12 `vaultlayer` `MEV` `MEDIUM` `NFTLendMarket.sol:517` `claimDefaultedLoan` — Function 'claimDefaultedLoan' is an order- or price-sensitive operation without slippage/deadline protection.
   signals: taint_reaches_flag, user_controlled_call_target, value_to_user, no_access_control

## Full ranking

| # | bucket | score | protocol | detector | severity | function | file:line |
|---|--------|-------|----------|----------|----------|----------|-----------|
| 1 | HIGH | 14 | morpho-blue | AccessControl | HIGH | liquidate | Morpho.sol:347 |
| 2 | HIGH | 12 | compound-v3 | OracleManipulation | HIGH | getPrice | CometWithExtendedAssetList.sol:345 |
| 3 | HIGH | 12 | grace | AccessControl | HIGH | withdraw | Pool.sol:313 |
| 4 | HIGH | 12 | grace | AccessControl | HIGH | redeem | Pool.sol:349 |
| 5 | HIGH | 12 | monolith-market | AccessControl | HIGH | withdraw | ERC4626.sol:73 |
| 6 | HIGH | 12 | monolith-market | AccessControl | HIGH | redeem | ERC4626.sol:95 |
| 7 | HIGH | 12 | monolith-market | Reentrancy | HIGH | liquidate | Lender.sol:286 |
| 8 | HIGH | 12 | monolith-market | AccessControl | HIGH | liquidate | Lender.sol:260 |
| 9 | HIGH | 12 | monolith-market | Reentrancy | HIGH | writeOff | Lender.sol:326 |
| 10 | HIGH | 12 | monolith-market | Reentrancy | HIGH | redeem | Lender.sol:347 |
| 11 | HIGH | 12 | monolith-market | AccessControl | HIGH | redeem | Lender.sol:339 |
| 12 | HIGH | 12 | morpho-blue | ValueFlow | HIGH | supply | Morpho.sol:183 |
| 13 | HIGH | 12 | morpho-blue | ValueFlow | HIGH | repay | Morpho.sol:283 |
| 14 | HIGH | 12 | vaultlayer | FrontRunning | MEDIUM | claimDefaultedLoan | NFTLendMarket.sol:517 |
| 15 | HIGH | 12 | vaultlayer | MEV | MEDIUM | claimDefaultedLoan | NFTLendMarket.sol:517 |
| 16 | HIGH | 12 | vaultlayer | ValueFlow | MEDIUM | claimDefaultedLoan | NFTLendMarket.sol:527 |
| 17 | HIGH | 11 | basis-cash | ValueFlow | MEDIUM | stake | LPTokenWrapper.sol:25 |
| 18 | HIGH | 11 | basis-cash | ValueFlow | MEDIUM | stake | BACDAIPool.sol:83 |
| 19 | HIGH | 11 | basis-cash | ValueFlow | MEDIUM | stake | BACSUSDPool.sol:83 |
| 20 | HIGH | 11 | basis-cash | ValueFlow | MEDIUM | stake | BACUSDCPool.sol:83 |
| 21 | HIGH | 11 | basis-cash | ValueFlow | MEDIUM | stake | BACyCRVPool.sol:83 |
| 22 | HIGH | 11 | basis-cash | ValueFlow | MEDIUM | stake | BACUSDTPool.sol:83 |
| 23 | HIGH | 11 | credit-guild | FrontRunning | MEDIUM | claimGaugeRewards | ProfitManager.sol:444 |
| 24 | HIGH | 11 | credit-guild | MEV | MEDIUM | claimGaugeRewards | ProfitManager.sol:444 |
| 25 | HIGH | 11 | grace | FrontRunning | MEDIUM | claimReferralRewards | Pool.sol:569 |
| 26 | HIGH | 11 | grace | MEV | MEDIUM | claimReferralRewards | Pool.sol:569 |
| 27 | HIGH | 11 | kpk | ZeroAddress | MEDIUM | requestSubscription | kpkShares.sol:217 |
| 28 | HIGH | 11 | kpk | ValueFlow | MEDIUM | requestSubscription | kpkShares.sol:231 |
| 29 | HIGH | 11 | kpk | ZeroAddress | MEDIUM | requestSubscription | kpkShares.sol:217 |
| 30 | HIGH | 11 | kpk | ValueFlow | MEDIUM | requestSubscription | kpkShares.sol:231 |
| 31 | HIGH | 11 | kpk | ZeroAddress | MEDIUM | requestSubscription | kpkShares.sol:217 |
| 32 | HIGH | 11 | kpk | ValueFlow | MEDIUM | requestSubscription | kpkShares.sol:231 |
| 33 | HIGH | 11 | kpk | ZeroAddress | MEDIUM | requestSubscription | kpkShares.sol:217 |
| 34 | HIGH | 11 | kpk | ValueFlow | MEDIUM | requestSubscription | kpkShares.sol:231 |
| 35 | HIGH | 11 | monolith-market | ValueFlow | MEDIUM | redeem | Lender.sol:346 |
| 36 | HIGH | 11 | rocket-pool | FrontRunning | MEDIUM | burn | RocketTokenRETH.sol:132 |
| 37 | HIGH | 11 | rocket-pool | MEV | MEDIUM | burn | RocketTokenRETH.sol:132 |
| 38 | HIGH | 11 | sushiswap | OracleTaint | MEDIUM | swapExactETHForTokens | UniswapV2Router02.sol:647 |
| 39 | HIGH | 11 | uniswap-v2 | OracleTaint | MEDIUM | swapExactETHForTokens | UniswapV2Router02.sol:476 |
| 40 | HIGH | 11 | vaultlayer | Timestamp | LOW | claimDefaultedLoan | NFTLendMarket.sol:517 |
| 41 | HIGH | 10 | compound-v3 | OracleManipulation | HIGH | quoteCollateral | CometWithExtendedAssetList.sol:1151 |
| 42 | HIGH | 10 | credit-guild | Reentrancy | HIGH | decrementGauge | ERC20Gauges.sol:285 |
| 43 | HIGH | 10 | credit-guild | Reentrancy | HIGH | decrementGauges | ERC20Gauges.sol:335 |
| 44 | HIGH | 10 | credit-guild | AccessControl | HIGH | distribute | ERC20RebaseDistributor.sol:342 |
| 45 | HIGH | 10 | grace | AccessControl | HIGH | mint | Pool.sol:289 |
| 46 | HIGH | 10 | hegic | CrossChain | HIGH | bridgeInit | StandardArbERC20.sol:43 |
| 47 | HIGH | 10 | monolith-market | AccessControl | HIGH | mint | ERC4626.sol:60 |
| 48 | HIGH | 10 | monolith-market | Reentrancy | HIGH | deploy | Factory.sol:154 |
| 49 | HIGH | 10 | monolith-market | Reentrancy | HIGH | adjust | Lender.sol:174 |
| 50 | HIGH | 10 | morpho-blue | AccessControl | HIGH | setAuthorizationWithSig | Morpho.sol:446 |
| 51 | HIGH | 10 | pumpclaw | AccessControl | HIGH | kill | LastAIStanding.sol:368 |
| 52 | HIGH | 10 | termmax | Reentrancy | HIGH | initialize | StableERC4626For4626.sol:39 |
| 53 | HIGH | 10 | termmax | Reentrancy | HIGH | initialize | StableERC4626For4626.sol:39 |
| 54 | HIGH | 10 | yieldnest | OracleManipulation | HIGH | getOperationState | TimelockController.sol:208 |
| 55 | HIGH | 10 | yieldnest | AccessControl | HIGH | updateDelay | TimelockController.sol:449 |
| 56 | HIGH | 10 | balancer-v2 | IntegerOverflow | MEDIUM | flashLoan | FlashLoans.sol:77 |
| 57 | HIGH | 10 | chi-protocol | FrontRunning | MEDIUM | burn | ArbitrageV5.sol:285 |
| 58 | HIGH | 10 | chi-protocol | MEV | MEDIUM | burn | ArbitrageV5.sol:285 |
| 59 | HIGH | 10 | kpk | ZeroAddress | MEDIUM | _rejectSubscriptionRequest | kpkShares.sol:799 |
| 60 | HIGH | 10 | kpk | ZeroAddress | MEDIUM | _rejectSubscriptionRequest | kpkShares.sol:799 |
| 61 | HIGH | 10 | kpk | ZeroAddress | MEDIUM | _rejectSubscriptionRequest | kpkShares.sol:799 |
| 62 | HIGH | 10 | kpk | ZeroAddress | MEDIUM | _rejectSubscriptionRequest | kpkShares.sol:799 |
| 63 | HIGH | 10 | credit-guild | Timestamp | LOW | getBidDetail | AuctionHouse.sol:128 |
| 64 | HIGH | 10 | kpk | Timestamp | LOW | cancelSubscription | kpkShares.sol:269 |
| 65 | HIGH | 10 | kpk | Timestamp | LOW | cancelSubscription | kpkShares.sol:269 |
| 66 | HIGH | 10 | kpk | Timestamp | LOW | cancelSubscription | kpkShares.sol:269 |
| 67 | HIGH | 10 | kpk | Timestamp | LOW | cancelSubscription | kpkShares.sol:269 |
| 68 | HIGH | 9 | credit-guild | Reentrancy | HIGH | _undelegate | ERC20MultiVotes.sol:390 |
| 69 | HIGH | 9 | credit-guild | Reentrancy | HIGH | _writeCheckpoint | ERC20MultiVotes.sol:414 |
| 70 | HIGH | 9 | credit-guild | Reentrancy | HIGH | _decrementVotesUntilFree | ERC20MultiVotes.sol:477 |
| 71 | HIGH | 9 | credit-guild | Reentrancy | HIGH | _incrementGaugeWeight | ERC20Gauges.sol:214 |
| 72 | HIGH | 9 | credit-guild | Reentrancy | HIGH | _decrementGaugeWeight | ERC20Gauges.sol:302 |
| 73 | HIGH | 9 | credit-guild | Reentrancy | HIGH | _decrementWeightUntilFree | ERC20Gauges.sol:489 |
| 74 | HIGH | 9 | dydx-v3 | OracleManipulation | HIGH | fetchPrice | SoloMargin.sol:1907 |
| 75 | HIGH | 9 | dydx-v3 | OracleManipulation | HIGH | getAccountValues | SoloMargin.sol:1942 |
| 76 | HIGH | 9 | dydx-v3 | OracleTaint | HIGH | getAccountValues | SoloMargin.sol:1942 |
| 77 | HIGH | 9 | dydx-v3 | OracleManipulation | HIGH | _setPriceOracle | SoloMargin.sol:2575 |
| 78 | HIGH | 9 | dydx-v3 | OracleManipulation | HIGH | _getLiquidationPrices | SoloMargin.sol:5559 |
| 79 | HIGH | 9 | dydx-v3 | OracleManipulation | HIGH | fetchPrice | OperationImpl.sol:2263 |
| 80 | HIGH | 9 | dydx-v3 | OracleManipulation | HIGH | getAccountValues | OperationImpl.sol:2298 |
| 81 | HIGH | 9 | dydx-v3 | OracleTaint | HIGH | getAccountValues | OperationImpl.sol:2298 |
| 82 | HIGH | 9 | dydx-v3 | OracleManipulation | HIGH | _getLiquidationPrices | OperationImpl.sol:4147 |
| 83 | HIGH | 9 | kpk | Reentrancy | HIGH | _updateAsset | kpkShares.sol:1056 |
| 84 | HIGH | 9 | kpk | Reentrancy | HIGH | _updateAsset | kpkShares.sol:1056 |
| 85 | HIGH | 9 | kpk | Reentrancy | HIGH | _updateAsset | kpkShares.sol:1056 |
| 86 | HIGH | 9 | kpk | Reentrancy | HIGH | _updateAsset | kpkShares.sol:1056 |
| 87 | HIGH | 9 | monolith-market | Reentrancy | HIGH | updateBorrower | Lender.sol:388 |
| 88 | HIGH | 9 | morpho-blue | Reentrancy | HIGH | _accrueInterest | Morpho.sol:489 |
| 89 | HIGH | 9 | compound-v2 | FrontRunning | MEDIUM | approve | CEther.sol:1131 |
| 90 | HIGH | 9 | compound-v2 | ZeroAddress | MEDIUM | _setComptroller | CEther.sol:2156 |
| 91 | HIGH | 9 | eigencloud | ZeroAddress | MEDIUM | setClaimerFor | RewardsCoordinator.sol:280 |
| 92 | HIGH | 9 | flex | ZeroAddress | MEDIUM |  | Strategy.sol:55 |
| 93 | HIGH | 9 | forta | ZeroAddress | MEDIUM | setAccessManager | AccessManaged.sol:56 |
| 94 | HIGH | 9 | grace | FrontRunning | MEDIUM | approve | Pool.sol:259 |
| 95 | HIGH | 9 | grace | FrontRunning | MEDIUM | mint | Pool.sol:303 |
| 96 | HIGH | 9 | grace | MEV | MEDIUM | mint | Pool.sol:303 |
| 97 | HIGH | 9 | harvest-finance | FrontRunning | MEDIUM | approve | OUSD.sol:404 |
| 98 | HIGH | 9 | harvest-finance | FrontRunning | MEDIUM | mint | OUSD.sol:414 |
| 99 | HIGH | 9 | harvest-finance | MEV | MEDIUM | mint | OUSD.sol:414 |
| 100 | HIGH | 9 | harvest-finance | FrontRunning | MEDIUM | burn | OUSD.sol:434 |
| 101 | HIGH | 9 | harvest-finance | MEV | MEDIUM | burn | OUSD.sol:434 |
| 102 | HIGH | 9 | levva | ZeroAddress | MEDIUM |  | LevvaPoolAdapter.sol:53 |
| 103 | HIGH | 9 | levva | ZeroAddress | MEDIUM |  | LevvaPoolAdapter.sol:53 |
| 104 | HIGH | 9 | levva | ZeroAddress | MEDIUM |  | LevvaPoolAdapter.sol:53 |
| 105 | HIGH | 9 | lido | IntegerOverflow | MEDIUM | isValidBump | Repo.sol:120 |
| 106 | HIGH | 9 | monolith-market | ValueFlow | MEDIUM | deposit | ERC4626.sol:48 |
| 107 | HIGH | 9 | monolith-market | FrontRunning | MEDIUM | approve | ERC20.sol:68 |
| 108 | HIGH | 9 | monolith-market | FrontRunning | MEDIUM | mint | Vault.sol:60 |
| 109 | HIGH | 9 | monolith-market | MEV | MEDIUM | mint | Vault.sol:60 |
| 110 | HIGH | 9 | monolith-market | ZeroAddress | MEDIUM |  | Lender.sol:80 |
| 111 | HIGH | 9 | termmax | ZeroAddress | MEDIUM | initialize | VariableERC4626ForAave.sol:38 |
| 112 | HIGH | 9 | termmax | ZeroAddress | MEDIUM | initialize | StableERC4626ForAave.sol:41 |
| 113 | HIGH | 9 | termmax | ZeroAddress | MEDIUM | initialize | StableERC4626For4626.sol:37 |
| 114 | HIGH | 9 | termmax | ZeroAddress | MEDIUM | initialize | VariableERC4626ForAave.sol:38 |
| 115 | HIGH | 9 | termmax | ZeroAddress | MEDIUM | initialize | StableERC4626ForAave.sol:41 |
| 116 | HIGH | 9 | termmax | ZeroAddress | MEDIUM | initialize | StableERC4626For4626.sol:37 |
| 117 | HIGH | 9 | treasure | ZeroAddress | MEDIUM | initialize | UniswapV2Pair.sol:69 |
| 118 | HIGH | 9 | treasure | ZeroAddress | MEDIUM | transferFrom | UniswapV2ERC20.sol:72 |
| 119 | HIGH | 9 | vaultlayer | FrontRunning | MEDIUM | updateAllowedNFT | NFTLendMarket.sol:193 |
| 120 | HIGH | 9 | wstgbp | ZeroAddress | MEDIUM |  | WsgemHookHelper.sol:64 |
| 121 | HIGH | 9 | vaultlayer | Timestamp | LOW | repayLoan | NFTLendMarket.sol:470 |
| 122 | HIGH | 8 | compound-v3 | SignatureReplay | CRITICAL | signed104 | CometMath.sol:34 |
| 123 | HIGH | 8 | compound-v3 | SignatureReplay | CRITICAL | signed256 | CometMath.sol:39 |
| 124 | HIGH | 8 | hegic | SignatureReplay | CRITICAL | recover | ECDSAUpgradeable.sol:53 |
| 125 | HIGH | 8 | basis-cash | AccessControl | HIGH | update | Oracle.sol:49 |
| 126 | HIGH | 8 | basis-cash | Reentrancy | HIGH | distribute | InitialCashDistributor.sol:42 |
| 127 | HIGH | 8 | basis-cash | AccessControl | HIGH | distribute | InitialCashDistributor.sol:33 |
| 128 | HIGH | 8 | basis-cash | Reentrancy | HIGH | distribute | InitialShareDistributor.sol:42 |
| 129 | HIGH | 8 | basis-cash | AccessControl | HIGH | distribute | InitialShareDistributor.sol:36 |
| 130 | HIGH | 8 | chi-protocol | Reentrancy | HIGH | rewardUSC | ArbitrageV5.sol:240 |
| 131 | HIGH | 8 | compound-v3 | OracleManipulation | HIGH | isBorrowCollateralized | CometWithExtendedAssetList.sol:386 |
| 132 | HIGH | 8 | compound-v3 | OracleManipulation | HIGH | isLiquidatable | CometWithExtendedAssetList.sol:429 |
| 133 | HIGH | 8 | convex-finance | AccessControl | HIGH | updateOperator | ConvexToken.sol:1083 |
| 134 | HIGH | 8 | credit-guild | Timestamp | HIGH | setProfitSharingConfig | ProfitManager.sol:204 |
| 135 | HIGH | 8 | ethena-usde | AccessControl | HIGH | acceptOwnership | Ownable2Step.sol:52 |
| 136 | HIGH | 8 | forta | AccessControl | HIGH | disableRouter | Routed.sol:21 |
| 137 | HIGH | 8 | lisk-bridge | AccessControl | HIGH | acceptOwnership | Ownable2Step.sol:52 |
| 138 | HIGH | 8 | monolith-market | Reentrancy | HIGH | accrueInterest | Lender.sol:141 |
| 139 | HIGH | 8 | monolith-market | Reentrancy | HIGH | pullLocalReserves | Lender.sol:602 |
| 140 | HIGH | 8 | monolith-market | Reentrancy | HIGH | pullGlobalReserves | Lender.sol:609 |
| 141 | HIGH | 8 | peer | AccessControl | HIGH | removeMembers | AddressGroupRegistry.sol:142 |
| 142 | HIGH | 8 | perpetual-protocol | AccessControl | HIGH | acceptOwnership | Ownable2Step.sol:52 |
| 143 | HIGH | 8 | treasure | AccessControl | HIGH | acceptOwnership | Ownable2Step.sol:52 |
| 144 | HIGH | 8 | treasure | Reentrancy | HIGH | setLpFee | UniswapV2Factory.sol:103 |
| 145 | HIGH | 8 | treasure | Reentrancy | HIGH | setRoyaltiesFee | UniswapV2Factory.sol:114 |
| 146 | HIGH | 8 | treasure | Reentrancy | HIGH | setProtocolFee | UniswapV2Factory.sol:126 |
| 147 | HIGH | 8 | treasure | Reentrancy | HIGH | initialize | UniswapV2Pair.sol:76 |
| 148 | HIGH | 8 | balancer-v2 | IntegerOverflow | MEDIUM | _decreaseInternalBalance | UserBalance.sol:193 |
| 149 | HIGH | 8 | balancer-v2 | IntegerOverflow | MEDIUM | _processJoinPoolTransfers | PoolBalances.sol:243 |
| 150 | HIGH | 8 | balancer-v2 | IntegerOverflow | MEDIUM | _processJoinPoolTransfers | PoolBalances.sol:242 |
| 151 | HIGH | 8 | balancer-v2 | IntegerOverflow | MEDIUM | _receiveAsset | AssetTransfersHandler.sol:72 |
| 152 | HIGH | 8 | balancer-v2 | IntegerOverflow | MEDIUM | _processGeneralPoolSwapRequest | Swaps.sol:411 |
| 153 | HIGH | 8 | balancer-v2 | IntegerOverflow | MEDIUM | _processGeneralPoolSwapRequest | Swaps.sol:412 |
| 154 | HIGH | 8 | chi-protocol | FrontRunning | MEDIUM | mint | ArbitrageV5.sol:247 |
| 155 | HIGH | 8 | chi-protocol | MEV | MEDIUM | mint | ArbitrageV5.sol:247 |
| 156 | HIGH | 8 | kpk | ZeroAddress | MEDIUM | _approveSubscriptionRequest | kpkShares.sol:772 |
| 157 | HIGH | 8 | kpk | ZeroAddress | MEDIUM | _approveSubscriptionRequest | kpkShares.sol:772 |
| 158 | HIGH | 8 | kpk | ZeroAddress | MEDIUM | _approveSubscriptionRequest | kpkShares.sol:772 |
| 159 | HIGH | 8 | kpk | ZeroAddress | MEDIUM | _approveSubscriptionRequest | kpkShares.sol:772 |
| 160 | HIGH | 8 | pumpclaw | ValueFlow | MEDIUM | register | LastAIStanding.sol:313 |
| 161 | HIGH | 8 | treasure | FrontRunning | MEDIUM | mint | UniswapV2Pair.sol:156 |
| 162 | HIGH | 8 | treasure | MEV | MEDIUM | mint | UniswapV2Pair.sol:156 |
| 163 | HIGH | 8 | treasure | FrontRunning | MEDIUM | burn | UniswapV2Pair.sol:178 |
| 164 | HIGH | 8 | treasure | MEV | MEDIUM | burn | UniswapV2Pair.sol:178 |
| 165 | HIGH | 8 | treasure | OracleTaint | MEDIUM | swap | UniswapV2Pair.sol:204 |
| 166 | HIGH | 8 | treasure | ZeroAddress | MEDIUM | _mint | UniswapV2ERC20.sol:39 |
| 167 | HIGH | 8 | treasure | ZeroAddress | MEDIUM | _burn | UniswapV2ERC20.sol:45 |
| 168 | HIGH | 8 | treasure | ZeroAddress | MEDIUM | _transfer | UniswapV2ERC20.sol:56 |
| 169 | HIGH | 8 | basis-cash | Timestamp | LOW | migrate | Treasury.sol:108 |
| 170 | HIGH | 8 | basis-cash | Timestamp | LOW | notifyRewardAmount | BACDAIPool.sol:208 |
| 171 | HIGH | 8 | basis-cash | Timestamp | LOW | notifyRewardAmount | BACSUSDPool.sol:208 |
| 172 | HIGH | 8 | basis-cash | Timestamp | LOW | notifyRewardAmount | BACUSDCPool.sol:208 |
| 173 | HIGH | 8 | basis-cash | Timestamp | LOW | notifyRewardAmount | DAIBACLPTokenSharePool.sol:189 |
| 174 | HIGH | 8 | basis-cash | Timestamp | LOW | notifyRewardAmount | BACyCRVPool.sol:208 |
| 175 | HIGH | 8 | basis-cash | Timestamp | LOW | notifyRewardAmount | DAIBASLPTokenSharePool.sol:178 |
| 176 | HIGH | 8 | basis-cash | Timestamp | LOW | notifyRewardAmount | BACUSDTPool.sol:208 |
| 177 | HIGH | 8 | credit-guild | Timestamp | LOW | partialRepayDelayPassed | LendingTerm.sol:337 |
| 178 | HIGH | 8 | yieldnest | Timestamp | LOW | getOperationState | TimelockController.sol:207 |
| 179 | MEDIUM | 7 | chi-protocol | Reentrancy | HIGH | _arbitrageAtPegExcessOfReserves | ArbitrageV5.sol:521 |
| 180 | MEDIUM | 7 | chi-protocol | Reentrancy | HIGH | _arbitrageAtPegDeficitOfReserves | ArbitrageV5.sol:548 |
| 181 | MEDIUM | 7 | credit-guild | Timestamp | HIGH | _borrow | LendingTerm.sol:450 |
| 182 | MEDIUM | 7 | credit-guild | Reentrancy | HIGH | _addGauge | ERC20Gauges.sol:378 |
| 183 | MEDIUM | 7 | credit-guild | Reentrancy | HIGH | _removeGauge | ERC20Gauges.sol:406 |
| 184 | MEDIUM | 7 | levva | Reentrancy | HIGH | _addPool | LevvaPoolAdapter.sol:339 |
| 185 | MEDIUM | 7 | levva | Reentrancy | HIGH | _addPool | LevvaPoolAdapter.sol:339 |
| 186 | MEDIUM | 7 | levva | Reentrancy | HIGH | _addPool | LevvaPoolAdapter.sol:339 |
| 187 | MEDIUM | 7 | treasure | Reentrancy | HIGH | _update | UniswapV2Pair.sol:103 |
| 188 | MEDIUM | 7 | across | ZeroAddress | MEDIUM | __setTarget | PermissionSplitterProxy.sol:40 |
| 189 | MEDIUM | 7 | balancer-v2 | ZeroAddress | MEDIUM |  | ProtocolFeesCollector.sol:57 |
| 190 | MEDIUM | 7 | basis-cash | IntegerOverflow | MEDIUM | update | Oracle.sol:55 |
| 191 | MEDIUM | 7 | basis-cash | IntegerOverflow | MEDIUM | update | Oracle.sol:65 |
| 192 | MEDIUM | 7 | basis-cash | IntegerOverflow | MEDIUM | update | Oracle.sol:68 |
| 193 | MEDIUM | 7 | basis-cash | ZeroAddress | MEDIUM |  | Timelock.sol:75 |
| 194 | MEDIUM | 7 | basis-cash | ZeroAddress | MEDIUM | setPendingAdmin | Timelock.sol:120 |
| 195 | MEDIUM | 7 | basis-cash | ZeroAddress | MEDIUM |  | Treasury.sol:50 |
| 196 | MEDIUM | 7 | basis-cash | FrontRunning | MEDIUM | burn | Bond.sol:30 |
| 197 | MEDIUM | 7 | basis-cash | MEV | MEDIUM | burn | Bond.sol:30 |
| 198 | MEDIUM | 7 | basis-cash | FrontRunning | MEDIUM | burn | Share.sol:29 |
| 199 | MEDIUM | 7 | basis-cash | MEV | MEDIUM | burn | Share.sol:29 |
| 200 | MEDIUM | 7 | basis-cash | FrontRunning | MEDIUM | burn | Cash.sol:42 |
| 201 | MEDIUM | 7 | basis-cash | MEV | MEDIUM | burn | Cash.sol:42 |
| 202 | MEDIUM | 7 | basis-cash | ZeroAddress | MEDIUM |  | Boardroom.sol:41 |
| 203 | MEDIUM | 7 | basis-cash | ZeroAddress | MEDIUM |  | InitialShareDistributor.sol:22 |
| 204 | MEDIUM | 7 | basis-cash | ZeroAddress | MEDIUM | setRewardDistribution | IRewardDistributionRecipient.sol:18 |
| 205 | MEDIUM | 7 | basis-cash | ZeroAddress | MEDIUM |  | BACDAIPool.sol:113 |
| 206 | MEDIUM | 7 | basis-cash | ZeroAddress | MEDIUM |  | BACSUSDPool.sol:113 |
| 207 | MEDIUM | 7 | basis-cash | ZeroAddress | MEDIUM |  | BACUSDCPool.sol:113 |
| 208 | MEDIUM | 7 | basis-cash | ZeroAddress | MEDIUM |  | DAIBACLPTokenSharePool.sol:88 |
| 209 | MEDIUM | 7 | basis-cash | ZeroAddress | MEDIUM |  | BACyCRVPool.sol:113 |
| 210 | MEDIUM | 7 | basis-cash | ZeroAddress | MEDIUM |  | DAIBASLPTokenSharePool.sol:87 |
| 211 | MEDIUM | 7 | basis-cash | ZeroAddress | MEDIUM |  | BACUSDTPool.sol:113 |
| 212 | MEDIUM | 7 | chi-protocol | ZeroAddress | MEDIUM |  | ArbitrageV5.sol:118 |
| 213 | MEDIUM | 7 | chi-protocol | ZeroAddress | MEDIUM | setReserveHolder | ArbitrageV5.sol:135 |
| 214 | MEDIUM | 7 | chi-protocol | FrontRunning | MEDIUM | executeArbitrageWithReserveSell | ArbitrageV5.sol:309 |
| 215 | MEDIUM | 7 | chi-protocol | MEV | MEDIUM | executeArbitrageWithReserveSell | ArbitrageV5.sol:309 |
| 216 | MEDIUM | 7 | compound-blue | ZeroAddress | MEDIUM |  | Hopscotch.sol:35 |
| 217 | MEDIUM | 7 | compound-v2 | ZeroAddress | MEDIUM | _setPendingAdmin | CEther.sol:2106 |
| 218 | MEDIUM | 7 | convex-finance | ZeroAddress | MEDIUM |  | ConvexToken.sol:1070 |
| 219 | MEDIUM | 7 | credit-guild | ZeroAddress | MEDIUM |  | RateLimitedMinter.sol:26 |
| 220 | MEDIUM | 7 | credit-guild | FrontRunning | MEDIUM | mint | RateLimitedMinter.sol:45 |
| 221 | MEDIUM | 7 | credit-guild | MEV | MEDIUM | mint | RateLimitedMinter.sol:45 |
| 222 | MEDIUM | 7 | credit-guild | Timestamp | MEDIUM | startAuction | AuctionHouse.sol:82 |
| 223 | MEDIUM | 7 | credit-guild | FrontRunning | MEDIUM | burn | CreditToken.sol:39 |
| 224 | MEDIUM | 7 | credit-guild | MEV | MEDIUM | burn | CreditToken.sol:39 |
| 225 | MEDIUM | 7 | dydx-v3 | ZeroAddress | MEDIUM |  | SoloMargin.sol:5685 |
| 226 | MEDIUM | 7 | ethena-usde | ZeroAddress | MEDIUM | setMinter | USDe.sol:22 |
| 227 | MEDIUM | 7 | flex | ZeroAddress | MEDIUM |  | TokenizedStrategy.sol:3374 |
| 228 | MEDIUM | 7 | flex | FrontRunning | MEDIUM | setAllowed | Strategy.sol:152 |
| 229 | MEDIUM | 7 | grace | ZeroAddress | MEDIUM |  | Pool.sol:59 |
| 230 | MEDIUM | 7 | grace | ZeroAddress | MEDIUM |  | API3Feed.sol:13 |
| 231 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | setFlywheelRewards | AddressesProvider.sol:65 |
| 232 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | setPlugin | AddressesProvider.sol:79 |
| 233 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | setRedemptionStrategy | AddressesProvider.sol:93 |
| 234 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | setFundingStrategy | AddressesProvider.sol:112 |
| 235 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | setAddress | AddressesProvider.sol:150 |
| 236 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | setBalancerPoolForTokens | AddressesProvider.sol:170 |
| 237 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | _setPendingOwner | SafeOwnableUpgradeable.sol:51 |
| 238 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | transferOwnership | SafeOwnableUpgradeable.sol:89 |
| 239 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | setFlywheelRewards | AddressesProvider.sol:65 |
| 240 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | setPlugin | AddressesProvider.sol:79 |
| 241 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | setRedemptionStrategy | AddressesProvider.sol:93 |
| 242 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | setFundingStrategy | AddressesProvider.sol:112 |
| 243 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | setAddress | AddressesProvider.sol:150 |
| 244 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | setBalancerPoolForTokens | AddressesProvider.sol:170 |
| 245 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | _setPendingOwner | SafeOwnableUpgradeable.sol:51 |
| 246 | MEDIUM | 7 | ionic-protocol | ZeroAddress | MEDIUM | transferOwnership | SafeOwnableUpgradeable.sol:89 |
| 247 | MEDIUM | 7 | lido | IntegerOverflow | MEDIUM | setABI | PublicResolver.sol:166 |
| 248 | MEDIUM | 7 | lido | IntegerOverflow | MEDIUM | getLatest | Repo.sol:82 |
| 249 | MEDIUM | 7 | lido | IntegerOverflow | MEDIUM | getVersionsCount | Repo.sol:108 |
| 250 | MEDIUM | 7 | lisk-bridge | FrontRunning | MEDIUM | burn | L1LiskToken.sol:58 |
| 251 | MEDIUM | 7 | lisk-bridge | MEV | MEDIUM | burn | L1LiskToken.sol:58 |
| 252 | MEDIUM | 7 | monolith-market | ZeroAddress | MEDIUM |  | Factory.sol:71 |
| 253 | MEDIUM | 7 | monolith-market | ZeroAddress | MEDIUM | setPendingOperator | Factory.sol:85 |
| 254 | MEDIUM | 7 | monolith-market | ZeroAddress | MEDIUM | setFeeRecipient | Factory.sol:95 |
| 255 | MEDIUM | 7 | monolith-market | ZeroAddress | MEDIUM |  | Vault.sol:19 |
| 256 | MEDIUM | 7 | monolith-market | ZeroAddress | MEDIUM | setPendingOperator | Lender.sol:585 |
| 257 | MEDIUM | 7 | monolith-market | ZeroAddress | MEDIUM |  | Coin.sol:10 |
| 258 | MEDIUM | 7 | morpho-blue | ZeroAddress | MEDIUM | setOwner | Morpho.sol:95 |
| 259 | MEDIUM | 7 | morpho-blue | ZeroAddress | MEDIUM | setFeeRecipient | Morpho.sol:139 |
| 260 | MEDIUM | 7 | perpetual-protocol | ZeroAddress | MEDIUM | setAddress | AddressManager.sol:35 |
| 261 | MEDIUM | 7 | sushiswap | ZeroAddress | MEDIUM |  | UniswapV2Router02.sol:409 |
| 262 | MEDIUM | 7 | termmax | ZeroAddress | MEDIUM |  | VariableERC4626ForAave.sol:32 |
| 263 | MEDIUM | 7 | termmax | ZeroAddress | MEDIUM |  | StableERC4626ForAave.sol:35 |
| 264 | MEDIUM | 7 | termmax | ZeroAddress | MEDIUM |  | TermMax4626Factory.sol:19 |
| 265 | MEDIUM | 7 | termmax | ZeroAddress | MEDIUM |  | VariableERC4626ForAave.sol:32 |
| 266 | MEDIUM | 7 | termmax | ZeroAddress | MEDIUM |  | StableERC4626ForAave.sol:35 |
| 267 | MEDIUM | 7 | termmax | ZeroAddress | MEDIUM |  | TermMax4626Factory.sol:19 |
| 268 | MEDIUM | 7 | treasure | ZeroAddress | MEDIUM | setDefaultFees | UniswapV2Factory.sol:90 |
| 269 | MEDIUM | 7 | truefi | ZeroAddress | MEDIUM | setFundsManager | TrueFiPool.sol:1980 |
| 270 | MEDIUM | 7 | truefi | ZeroAddress | MEDIUM | setTruOracle | TrueFiPool.sol:1989 |
| 271 | MEDIUM | 7 | truefi | ZeroAddress | MEDIUM | setCrvOracle | TrueFiPool.sol:1998 |
| 272 | MEDIUM | 7 | truefi | ZeroAddress | MEDIUM | setSafuAddress | TrueFiPool.sol:2015 |
| 273 | MEDIUM | 7 | truefi | IntegerOverflow | MEDIUM | sellCrv | TrueFiPool.sol:2289 |
| 274 | MEDIUM | 7 | uniswap-v2 | ZeroAddress | MEDIUM |  | UniswapV2Router02.sol:238 |
| 275 | MEDIUM | 7 | vaultlayer | FrontRunning | MEDIUM | updateAllowedERC20 | NFTLendMarket.sol:205 |
| 276 | MEDIUM | 7 | wildcat-protocol | IntegerOverflow | MEDIUM | requestOwnershipHandover | Ownable.sol:163 |
| 277 | MEDIUM | 7 | yearn-finance | ZeroAddress | MEDIUM | setGovernance | YFI.sol:211 |
| 278 | MEDIUM | 7 | credit-guild | Timestamp | LOW | _repay | LendingTerm.sol:692 |
| 279 | MEDIUM | 7 | credit-guild | Timestamp | LOW | _call | LendingTerm.sol:760 |
| 280 | MEDIUM | 7 | vaultlayer | Timestamp | LOW | cancelBid | NFTLendMarket.sol:501 |
| 281 | MEDIUM | 6 | angle | Timestamp | MEDIUM | _checkpoint | MockCurveTokenStakerAaveBP.sol:2832 |
| 282 | MEDIUM | 6 | balancer-v2 | ZeroAddress | MEDIUM | _setAuthorizer | VaultAuthorization.sol:88 |
| 283 | MEDIUM | 6 | balancer-v2 | IntegerOverflow | MEDIUM | _handleRemainingEth | AssetTransfersHandler.sol:131 |
| 284 | MEDIUM | 6 | chi-protocol | FrontRunning | MEDIUM | mint | ArbitrageV5.sol:266 |
| 285 | MEDIUM | 6 | chi-protocol | MEV | MEDIUM | mint | ArbitrageV5.sol:266 |
| 286 | MEDIUM | 6 | chi-protocol | FrontRunning | MEDIUM | executeArbitrage | ArbitrageV5.sol:323 |
| 287 | MEDIUM | 6 | chi-protocol | MEV | MEDIUM | executeArbitrage | ArbitrageV5.sol:323 |
| 288 | MEDIUM | 6 | compound-v2 | ZeroAddress | MEDIUM | _setInterestRateModelFresh | CEther.sol:2311 |
| 289 | MEDIUM | 6 | compound-v2 | IntegerOverflow | MEDIUM | requireNoError | CEther.sol:2525 |
| 290 | MEDIUM | 6 | compound-v2 | IntegerOverflow | MEDIUM | requireNoError | CEther.sol:2534 |
| 291 | MEDIUM | 6 | compound-v2 | IntegerOverflow | MEDIUM | requireNoError | CEther.sol:2535 |
| 292 | MEDIUM | 6 | compound-v3 | ZeroAddress | MEDIUM | updateAssetsIn | CometWithExtendedAssetList.sol:604 |
| 293 | MEDIUM | 6 | compound-v3 | ZeroAddress | MEDIUM | updateBasePrincipal | CometWithExtendedAssetList.sol:634 |
| 294 | MEDIUM | 6 | credit-guild | IntegerOverflow | MEDIUM | _transfer | ERC20.sol:234 |
| 295 | MEDIUM | 6 | credit-guild | IntegerOverflow | MEDIUM | _mint | ERC20.sol:259 |
| 296 | MEDIUM | 6 | credit-guild | IntegerOverflow | MEDIUM | _burn | ERC20.sol:287 |
| 297 | MEDIUM | 6 | credit-guild | ZeroAddress | MEDIUM | _setCore | CoreRef.sol:49 |
| 298 | MEDIUM | 6 | credit-guild | BadRandomness | MEDIUM | _borrow | LendingTerm.sol:459 |
| 299 | MEDIUM | 6 | credit-guild | IntegerOverflow | MEDIUM | updateTotalRebasingShares | ERC20RebaseDistributor.sol:174 |
| 300 | MEDIUM | 6 | eigencloud | ZeroAddress | MEDIUM | _setRewardsUpdater | RewardsCoordinator.sol:384 |
| 301 | MEDIUM | 6 | ethena-usde | IntegerOverflow | MEDIUM | _transfer | ERC20.sol:234 |
| 302 | MEDIUM | 6 | ethena-usde | IntegerOverflow | MEDIUM | _mint | ERC20.sol:259 |
| 303 | MEDIUM | 6 | ethena-usde | IntegerOverflow | MEDIUM | _burn | ERC20.sol:287 |
| 304 | MEDIUM | 6 | flex | IntegerOverflow | MEDIUM | _transfer | ERC20.sol:234 |
| 305 | MEDIUM | 6 | flex | IntegerOverflow | MEDIUM | _mint | ERC20.sol:259 |
| 306 | MEDIUM | 6 | flex | IntegerOverflow | MEDIUM | _burn | ERC20.sol:287 |
| 307 | MEDIUM | 6 | forta | ZeroAddress | MEDIUM | __AccessManaged_init | AccessManaged.sol:36 |
| 308 | MEDIUM | 6 | kpk | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:235 |
| 309 | MEDIUM | 6 | kpk | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:230 |
| 310 | MEDIUM | 6 | kpk | ZeroAddress | MEDIUM | _initializeState | kpkShares.sol:665 |
| 311 | MEDIUM | 6 | kpk | ZeroAddress | MEDIUM | _setFeeReceiver | kpkShares.sol:1102 |
| 312 | MEDIUM | 6 | kpk | ZeroAddress | MEDIUM | _setPerformanceFeeModule | kpkShares.sol:1141 |
| 313 | MEDIUM | 6 | kpk | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:235 |
| 314 | MEDIUM | 6 | kpk | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:230 |
| 315 | MEDIUM | 6 | kpk | ZeroAddress | MEDIUM | _initializeState | kpkShares.sol:665 |
| 316 | MEDIUM | 6 | kpk | ZeroAddress | MEDIUM | _setFeeReceiver | kpkShares.sol:1102 |
| 317 | MEDIUM | 6 | kpk | ZeroAddress | MEDIUM | _setPerformanceFeeModule | kpkShares.sol:1141 |
| 318 | MEDIUM | 6 | kpk | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:235 |
| 319 | MEDIUM | 6 | kpk | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:230 |
| 320 | MEDIUM | 6 | kpk | ZeroAddress | MEDIUM | _initializeState | kpkShares.sol:665 |
| 321 | MEDIUM | 6 | kpk | ZeroAddress | MEDIUM | _setFeeReceiver | kpkShares.sol:1102 |
| 322 | MEDIUM | 6 | kpk | ZeroAddress | MEDIUM | _setPerformanceFeeModule | kpkShares.sol:1141 |
| 323 | MEDIUM | 6 | kpk | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:235 |
| 324 | MEDIUM | 6 | kpk | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:230 |
| 325 | MEDIUM | 6 | kpk | ZeroAddress | MEDIUM | _initializeState | kpkShares.sol:665 |
| 326 | MEDIUM | 6 | kpk | ZeroAddress | MEDIUM | _setFeeReceiver | kpkShares.sol:1102 |
| 327 | MEDIUM | 6 | kpk | ZeroAddress | MEDIUM | _setPerformanceFeeModule | kpkShares.sol:1141 |
| 328 | MEDIUM | 6 | lido | ZeroAddress | MEDIUM | _setPermissionManager | ACL.sol:455 |
| 329 | MEDIUM | 6 | lisk-bridge | IntegerOverflow | MEDIUM | _update | ERC20.sol:211 |
| 330 | MEDIUM | 6 | lisk-bridge | IntegerOverflow | MEDIUM | _update | ERC20.sol:206 |
| 331 | MEDIUM | 6 | open-dollar | IntegerOverflow | MEDIUM | _transfer | ERC20Upgradeable.sol:239 |
| 332 | MEDIUM | 6 | open-dollar | IntegerOverflow | MEDIUM | _mint | ERC20Upgradeable.sol:264 |
| 333 | MEDIUM | 6 | open-dollar | IntegerOverflow | MEDIUM | _burn | ERC20Upgradeable.sol:292 |
| 334 | MEDIUM | 6 | peer | ZeroAddress | MEDIUM | _createGroup | AddressGroupRegistry.sol:245 |
| 335 | MEDIUM | 6 | pendle | UncheckedCall | MEDIUM | _delegateToSelf | ActionBase.sol:424 |
| 336 | MEDIUM | 6 | termmax | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:230 |
| 337 | MEDIUM | 6 | termmax | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:225 |
| 338 | MEDIUM | 6 | termmax | ZeroAddress | MEDIUM | _updateBufferConfig | VariableERC4626ForAave.sol:90 |
| 339 | MEDIUM | 6 | termmax | ZeroAddress | MEDIUM | _updateBufferConfig | StableERC4626ForAave.sol:142 |
| 340 | MEDIUM | 6 | termmax | ZeroAddress | MEDIUM | _updateBufferConfig | StableERC4626For4626.sol:140 |
| 341 | MEDIUM | 6 | termmax | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:230 |
| 342 | MEDIUM | 6 | termmax | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:225 |
| 343 | MEDIUM | 6 | termmax | ZeroAddress | MEDIUM | _updateBufferConfig | VariableERC4626ForAave.sol:90 |
| 344 | MEDIUM | 6 | termmax | ZeroAddress | MEDIUM | _updateBufferConfig | StableERC4626ForAave.sol:142 |
| 345 | MEDIUM | 6 | termmax | ZeroAddress | MEDIUM | _updateBufferConfig | StableERC4626For4626.sol:140 |
| 346 | MEDIUM | 6 | treasure | OracleTaint | MEDIUM | mint | UniswapV2Pair.sol:157 |
| 347 | MEDIUM | 6 | treasure | OracleTaint | MEDIUM | burn | UniswapV2Pair.sol:179 |
| 348 | MEDIUM | 6 | yieldnest | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:235 |
| 349 | MEDIUM | 6 | yieldnest | IntegerOverflow | MEDIUM | _update | ERC20Upgradeable.sol:230 |
| 350 | MEDIUM | 6 | yieldnest | IntegerOverflow | MEDIUM | _update | ERC20.sol:211 |
| 351 | MEDIUM | 6 | yieldnest | IntegerOverflow | MEDIUM | _update | ERC20.sol:206 |
| 352 | MEDIUM | 6 | eigencloud | Timestamp | LOW | submitRoot | RewardsCoordinator.sol:243 |
| 353 | MEDIUM | 6 | eigencloud | Timestamp | LOW | disableRoot | RewardsCoordinator.sol:270 |
| 354 | MEDIUM | 6 | eigencloud | Timestamp | LOW | getCurrentClaimableDistributionRoot | RewardsCoordinator.sol:705 |
| 355 | MEDIUM | 6 | kpk | Timestamp | LOW | cancelRedemption | kpkShares.sol:383 |
| 356 | MEDIUM | 6 | kpk | Timestamp | LOW | cancelRedemption | kpkShares.sol:383 |
| 357 | MEDIUM | 6 | kpk | Timestamp | LOW | cancelRedemption | kpkShares.sol:383 |
| 358 | MEDIUM | 6 | kpk | Timestamp | LOW | cancelRedemption | kpkShares.sol:383 |
| 359 | MEDIUM | 6 | liveart | Timestamp | LOW | stake | ArtStaking.sol:235 |
| 360 | MEDIUM | 6 | liveart | Timestamp | LOW | isCliffPeriod | ArtStaking.sol:298 |
| 361 | MEDIUM | 5 | compound-v3 | OracleManipulation | HIGH | absorbInternal | CometWithExtendedAssetList.sol:1065 |
| 362 | MEDIUM | 5 | compound-v3 | OracleTaint | HIGH | absorbInternal | CometWithExtendedAssetList.sol:1065 |
| 363 | MEDIUM | 5 | compound-v3 | OracleTaint | HIGH | absorbInternal | CometWithExtendedAssetList.sol:1076 |
| 364 | MEDIUM | 5 | grace | Reentrancy | HIGH | accrueInterest | Pool.sol:119 |
| 365 | MEDIUM | 5 | lido | OracleManipulation | HIGH | _evalParam | ACL.sol:347 |
| 366 | MEDIUM | 5 | lido | OracleManipulation | HIGH | getTimestamp64 | TimeHelpers.sol:46 |
| 367 | MEDIUM | 5 | basis-cash | IntegerOverflow | MEDIUM |  | Share.sol:10 |
| 368 | MEDIUM | 5 | basis-cash | IntegerOverflow | MEDIUM |  | Cash.sol:13 |
| 369 | MEDIUM | 5 | basis-cash | IntegerOverflow | MEDIUM |  | MockDai.sol:11 |
| 370 | MEDIUM | 5 | lido | IntegerOverflow | MEDIUM | newVersion | Repo.sol:53 |
| 371 | MEDIUM | 5 | credit-guild | Timestamp | LOW | _partialRepay | LendingTerm.sol:613 |
| 372 | MEDIUM | 5 | credit-guild | Timestamp | LOW | _checkDelegateLockupPeriod | ERC20MultiVotes.sol:148 |
| 373 | MEDIUM | 5 | credit-guild | Timestamp | LOW | interpolatedValue | ERC20RebaseDistributor.sol:132 |
| 374 | MEDIUM | 5 | eigencloud | Timestamp | LOW | _setOperatorSplit | RewardsCoordinator.sol:395 |
| 375 | MEDIUM | 5 | eigencloud | Timestamp | LOW | _validateCommonRewardsSubmission | RewardsCoordinator.sol:414 |
| 376 | MEDIUM | 5 | eigencloud | Timestamp | LOW | _validateRewardsSubmission | RewardsCoordinator.sol:459 |
| 377 | MEDIUM | 5 | eigencloud | Timestamp | LOW | _validateOperatorDirectedRewardsSubmission | RewardsCoordinator.sol:482 |
| 378 | MEDIUM | 5 | eigencloud | Timestamp | LOW | _checkClaim | RewardsCoordinator.sol:528 |
| 379 | MEDIUM | 5 | eigencloud | Timestamp | LOW | _getOperatorSplit | RewardsCoordinator.sol:633 |
| 380 | MEDIUM | 5 | flex | Timestamp | LOW | _unlockedShares | TokenizedStrategy.sol:2607 |
| 381 | MEDIUM | 5 | honeyswap | Timestamp | LOW | _isActive | GlobalPauseController.sol:75 |
| 382 | MEDIUM | 5 | liveart | Timestamp | LOW | _hasStakeMatured | ArtStaking.sol:368 |
| 383 | MEDIUM | 5 | pendle | Timestamp | LOW | isTimeInThePast | MiniHelpers.sol:13 |
| 384 | LOW | 4 | angle | ZeroAddress | MEDIUM |  | BaseLevSwapperMorpho.sol:23 |
| 385 | LOW | 4 | balancer-v2 | IntegerOverflow | MEDIUM | registerPool | PoolRegistry.sol:82 |
| 386 | LOW | 4 | balancer-v2 | IntegerOverflow | MEDIUM | _toPoolId | PoolRegistry.sol:123 |
| 387 | LOW | 4 | balancer-v2 | IntegerOverflow | MEDIUM | _toPoolId | PoolRegistry.sol:124 |
| 388 | LOW | 4 | balancer-v2 | IntegerOverflow | MEDIUM | _getPoolAddress | PoolRegistry.sol:137 |
| 389 | LOW | 4 | balancer-v2 | IntegerOverflow | MEDIUM | _getPoolSpecialization | PoolRegistry.sol:147 |
| 390 | LOW | 4 | balancer-v2 | IntegerOverflow | MEDIUM | _getPoolSpecialization | PoolRegistry.sol:147 |
| 391 | LOW | 4 | balancer-v2 | IntegerOverflow | MEDIUM | _getPoolSpecialization | PoolRegistry.sol:147 |
| 392 | LOW | 4 | balancer-v2 | IntegerOverflow | MEDIUM |  | TemporarilyPausable.sol:52 |
| 393 | LOW | 4 | balancer-v2 | IntegerOverflow | MEDIUM |  | TemporarilyPausable.sol:55 |
| 394 | LOW | 4 | credit-guild | ZeroAddress | MEDIUM |  | CoreRef.sol:19 |
| 395 | LOW | 4 | forta | ZeroAddress | MEDIUM |  | ForwardedContext.sol:14 |
| 396 | LOW | 4 | lido | IntegerOverflow | MEDIUM | decodeParamOp | ACLSyntaxSugar.sol:92 |
| 397 | LOW | 4 | lido | IntegerOverflow | MEDIUM | decodeParamId | ACLSyntaxSugar.sol:96 |
| 398 | LOW | 4 | lido | IntegerOverflow | MEDIUM | decodeParamsList | ACLSyntaxSugar.sol:101 |
| 399 | LOW | 4 | lido | IntegerOverflow | MEDIUM | decodeParamsList | ACLSyntaxSugar.sol:102 |
| 400 | LOW | 4 | rocket-pool | ZeroAddress | MEDIUM |  | RocketBase.sol:105 |
| 401 | LOW | 4 | treasure | IntegerOverflow | MEDIUM | _update | UniswapV2Pair.sol:95 |
| 402 | LOW | 4 | uniswap-v3 | ZeroAddress | MEDIUM |  | PeripheryImmutableState.sol:14 |
| 403 | LOW | 4 | basis-cash | Timestamp | LOW | _allocateSeigniorage | Treasury.sol:139 |
| 404 | LOW | 3 | compound-v3 | Timestamp | LOW | getNowInternal | CometWithExtendedAssetList.sol:246 |
| 405 | LOW | 3 | flex | Timestamp | LOW | report | TokenizedStrategy.sol:2413 |
| 406 | LOW | 2 | grace | Reentrancy | HIGH | None | Pool.sol:89 |
| 407 | LOW | 2 | grace | Reentrancy | HIGH | None | Pool.sol:89 |
| 408 | LOW | 2 | grace | Reentrancy | HIGH | None | Pool.sol:89 |
| 409 | LOW | 2 | grace | Reentrancy | HIGH | None | Pool.sol:89 |
| 410 | LOW | 2 | grace | Reentrancy | HIGH | None | Pool.sol:89 |
| 411 | LOW | 2 | grace | Reentrancy | HIGH | None | Pool.sol:89 |
| 412 | LOW | 2 | grace | Reentrancy | HIGH | None | Pool.sol:89 |
| 413 | LOW | 2 | grace | Reentrancy | HIGH | None | Pool.sol:89 |
| 414 | LOW | 2 | grace | Reentrancy | HIGH | None | Pool.sol:89 |
| 415 | LOW | 1 | angle | StorageCollision | MEDIUM | None | MockCurveTokenStakerAaveBP.sol:2915 |
| 416 | LOW | 1 | compound-v3 | Uninitialized | MEDIUM | None | CometStorage.sol:63 |
| 417 | LOW | 1 | credit-guild | Uninitialized | MEDIUM | None | EIP712.sol:52 |
| 418 | LOW | 1 | credit-guild | Uninitialized | MEDIUM | None | EIP712.sol:53 |
| 419 | LOW | 1 | credit-guild | StorageCollision | MEDIUM | None | ProfitManager.sol:29 |
| 420 | LOW | 1 | credit-guild | StorageCollision | MEDIUM | None | LendingTerm.sol:20 |
| 421 | LOW | 1 | credit-guild | StorageCollision | MEDIUM | None | CreditToken.sol:18 |
| 422 | LOW | 1 | credit-guild | StorageCollision | MEDIUM | None | GuildToken.sol:37 |
| 423 | LOW | 1 | eigencloud | StorageCollision | MEDIUM | None | RewardsCoordinator.sol:21 |
| 424 | LOW | 1 | eigencloud | Uninitialized | MEDIUM | None | RewardsCoordinatorStorage.sol:96 |
| 425 | LOW | 1 | eigencloud | Uninitialized | MEDIUM | None | RewardsCoordinatorStorage.sol:99 |
| 426 | LOW | 1 | ethena-usde | Uninitialized | MEDIUM | None | EIP712.sol:52 |
| 427 | LOW | 1 | ethena-usde | Uninitialized | MEDIUM | None | EIP712.sol:53 |
| 428 | LOW | 1 | ethena-usde | StorageCollision | MEDIUM | None | USDe.sol:14 |
| 429 | LOW | 1 | forta | StorageCollision | MEDIUM | None | FortaStaking.sol:52 |
| 430 | LOW | 1 | forta | StorageCollision | MEDIUM | None | StakeSubjectGateway.sol:16 |
| 431 | LOW | 1 | forta | StorageCollision | MEDIUM | None | RewardsDistributor.sol:20 |
| 432 | LOW | 1 | hegic | StorageCollision | MEDIUM | None | StandardArbERC20.sol:29 |
| 433 | LOW | 1 | honeyswap | StorageCollision | MEDIUM | None | GlobalPauseController.sol:6 |
| 434 | LOW | 1 | ionic-protocol | StorageCollision | MEDIUM | None | AddressesProvider.sol:12 |
| 435 | LOW | 1 | ionic-protocol | StorageCollision | MEDIUM | None | AddressesProvider.sol:12 |
| 436 | LOW | 1 | kpk | StorageCollision | MEDIUM | None | KpkOivFactory.sol:76 |
| 437 | LOW | 1 | kpk | StorageCollision | MEDIUM | None | kpkShares.sol:22 |
| 438 | LOW | 1 | kpk | StorageCollision | MEDIUM | None | KpkOivFactory.sol:76 |
| 439 | LOW | 1 | kpk | StorageCollision | MEDIUM | None | kpkShares.sol:22 |
| 440 | LOW | 1 | kpk | StorageCollision | MEDIUM | None | KpkOivFactory.sol:76 |
| 441 | LOW | 1 | kpk | StorageCollision | MEDIUM | None | kpkShares.sol:22 |
| 442 | LOW | 1 | kpk | StorageCollision | MEDIUM | None | KpkOivFactory.sol:76 |
| 443 | LOW | 1 | kpk | StorageCollision | MEDIUM | None | kpkShares.sol:22 |
| 444 | LOW | 1 | lisk-bridge | Uninitialized | MEDIUM | None | EIP712.sol:51 |
| 445 | LOW | 1 | lisk-bridge | Uninitialized | MEDIUM | None | EIP712.sol:52 |
| 446 | LOW | 1 | open-dollar | StorageCollision | MEDIUM | None | SystemCoin.sol:37 |
| 447 | LOW | 1 | truefi | StorageCollision | MEDIUM | None | TrueFiPool.sol:1759 |

## Per-protocol summary

| protocol | HIGH | MEDIUM | LOW |
|----------|------|--------|-----|
| kpk | 24 | 24 | 8 |
| monolith-market | 20 | 6 | 0 |
| basis-cash | 19 | 25 | 1 |
| treasure | 15 | 4 | 1 |
| credit-guild | 14 | 20 | 7 |
| dydx-v3 | 9 | 1 | 0 |
| grace | 8 | 3 | 9 |
| termmax | 8 | 16 | 0 |
| balancer-v2 | 7 | 3 | 9 |
| compound-v3 | 6 | 5 | 2 |
| vaultlayer | 6 | 2 | 0 |
| morpho-blue | 5 | 2 | 0 |
| chi-protocol | 5 | 10 | 0 |
| harvest-finance | 5 | 0 | 0 |
| yieldnest | 3 | 4 | 0 |
| levva | 3 | 3 | 0 |
| rocket-pool | 2 | 0 | 1 |
| hegic | 2 | 0 | 1 |
| pumpclaw | 2 | 0 | 0 |
| compound-v2 | 2 | 5 | 0 |
| forta | 2 | 1 | 4 |
| sushiswap | 1 | 1 | 0 |
| uniswap-v2 | 1 | 1 | 0 |
| eigencloud | 1 | 10 | 3 |
| flex | 1 | 6 | 1 |
| lido | 1 | 7 | 4 |
| wstgbp | 1 | 0 | 0 |
| convex-finance | 1 | 1 | 0 |
| ethena-usde | 1 | 4 | 3 |
| lisk-bridge | 1 | 4 | 2 |
| peer | 1 | 1 | 0 |
| perpetual-protocol | 1 | 1 | 0 |
| across | 0 | 1 | 0 |
| compound-blue | 0 | 1 | 0 |
| ionic-protocol | 0 | 16 | 2 |
| truefi | 0 | 5 | 1 |
| wildcat-protocol | 0 | 1 | 0 |
| yearn-finance | 0 | 1 | 0 |
| angle | 0 | 1 | 2 |
| open-dollar | 0 | 3 | 1 |
| pendle | 0 | 2 | 0 |
| liveart | 0 | 3 | 0 |
| honeyswap | 0 | 1 | 1 |
| uniswap-v3 | 0 | 0 | 1 |
