// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import { ICErc20 } from "../src/compound/CTokenInterfaces.sol";
import { IonicComptroller } from "../src/compound/ComptrollerInterface.sol";
import { InterestRateModel } from "../src/compound/InterestRateModel.sol";
import { CErc20Delegator } from "../src/compound/CErc20Delegator.sol";
import { CErc20Delegate } from "../src/compound/CErc20Delegate.sol";
import { CTokenFirstExtension } from "../src/compound/CTokenFirstExtension.sol";
import { AddressesProvider } from "../src/ionic/AddressesProvider.sol";
import { PoolLens } from "../src/PoolLens.sol";
import { IonicUniV3Liquidator } from "../src/IonicUniV3Liquidator.sol";

import { SimpleComptroller } from "./mocks/SimpleComptroller.sol";
import { SimpleInterestRateModel } from "./mocks/SimpleInterestRateModel.sol";
import { MockFeeDistributor } from "./mocks/MockFeeDistributor.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { Actor } from "./Actor.sol";

interface Vm {
    function roll(uint256) external;
}

/// @notice Invariant harness for Ionic Protocol's CErc20Delegator diamond
/// (vendored `development` snapshot, solc 0.8.10, evm shanghai). Two markets
/// (cUSDC, cWETH) share a permissive SimpleComptroller, a constant-rate
/// SimpleInterestRateModel, one MockFeeDistributor (the `ionicAdmin`) and one
/// AddressesProvider. Every user action is routed through real Actor contracts
/// so all value transfers are atomic EVM calls. Each successful action rolls
/// the block so `accrueInterest` sees a positive block delta.
contract IonicHandler {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint8 internal constant ACTORS = 4;
    uint8 internal constant MARKETS = 2;
    uint256 public constant ROUNDING_TOLERANCE = 1e9;

    /// @dev totalPenalty = liquidationIncentive (1.08) + protocolSeizeShare
    /// (2.8%) + feeSeizeShare (10%) used by SimpleComptroller's faithful
    /// `liquidateCalculateSeizeTokens`.
    uint256 internal constant TOTAL_SEIZE_PENALTY = 1.208e18;

    SimpleComptroller public comptroller;
    SimpleInterestRateModel public interestRateModel;
    MockFeeDistributor public feeDistributor;
    AddressesProvider public ap;
    PoolLens public lens;
    IonicUniV3Liquidator public liquidator;

    MockERC20[2] public underlyings;
    ICErc20[2] public markets;

    Actor[ACTORS] public actors;

    /// @notice total underlying minted to actors at setup, per market. No
    /// further mints happen during fuzzing, so this is the conservation
    /// constant checked by `checkUnderlyingConservation`.
    uint256[MARKETS] public totalUnderlyingMinted;

    constructor() {
        comptroller = new SimpleComptroller();
        interestRateModel = new SimpleInterestRateModel();

        underlyings[0] = new MockERC20("USDC", "USDC", 6);
        underlyings[1] = new MockERC20("WETH", "WETH", 18);

        address cErc20Delegate = address(new CErc20Delegate());
        address cTokenFirstExtension = address(new CTokenFirstExtension());
        feeDistributor = new MockFeeDistributor(cErc20Delegate, cTokenFirstExtension);

        ap = new AddressesProvider();
        ap.initialize(address(this));
        lens = new PoolLens();
        liquidator = new IonicUniV3Liquidator();
        ap.setAddress("PoolLens", address(lens));
        ap.setAddress("IonicUniV3Liquidator", address(liquidator));

        for (uint8 i = 0; i < MARKETS; i++) {
            string memory nm = i == 0 ? "cUSDC" : "cWETH";
            CErc20Delegator m = CErc20Delegator(
                feeDistributor.deployMarket(
                    address(underlyings[i]),
                    IonicComptroller(address(comptroller)),
                    interestRateModel,
                    nm,
                    nm,
                    0,
                    0
                )
            );
            m._setImplementationSafe(cErc20Delegate, "");
            (bool ok, ) = address(m).call(abi.encodeWithSignature("_setAddressesProvider(address)", address(ap)));
            require(ok, "set ap failed");
            comptroller.setMarket(address(m), 0.8e18);
            markets[i] = ICErc20(address(m));
        }

        uint256[MARKETS] memory funding = [uint256(1_000_000e6), uint256(10_000e18)];
        for (uint8 i = 0; i < ACTORS; i++) {
            actors[i] = new Actor();
            for (uint8 u = 0; u < MARKETS; u++) {
                underlyings[u].mint(address(actors[i]), funding[u]);
                totalUnderlyingMinted[u] += funding[u];
                actors[i].approveUnderlying(address(underlyings[u]), address(markets[u]));
            }
        }
    }

    /// @dev maps a fuzzed uint into [0, max] without modulo-by-zero.
    function _bounded(uint256 v, uint256 max) internal pure returns (uint256) {
        if (max == 0) return 0;
        if (max == type(uint256).max) return v;
        return v % (max + 1);
    }

    // ============================================================
    //  Actor actions
    // ============================================================

    function actorMint(uint8 actorIdx, uint8 marketIdx, uint256 amount) public {
        Actor a = actors[actorIdx % ACTORS];
        ICErc20 m = markets[marketIdx % MARKETS];
        MockERC20 u = underlyings[marketIdx % MARKETS];
        amount = _bounded(amount, u.balanceOf(address(a)));
        if (amount == 0) return;
        (bool ok, ) = address(a).call(abi.encodeWithSelector(a.mint.selector, address(m), amount));
        if (!ok) return;
        _tick();
    }

    function actorRedeem(uint8 actorIdx, uint8 marketIdx, uint256 redeemTokens) public {
        Actor a = actors[actorIdx % ACTORS];
        ICErc20 m = markets[marketIdx % MARKETS];
        redeemTokens = _bounded(redeemTokens, m.balanceOf(address(a)));
        if (redeemTokens == 0) return;
        (bool ok, ) = address(a).call(abi.encodeWithSelector(a.redeem.selector, address(m), redeemTokens));
        if (!ok) return;
        _tick();
    }

    function actorBorrow(uint8 actorIdx, uint8 marketIdx, uint256 borrowAmount) public {
        Actor a = actors[actorIdx % ACTORS];
        ICErc20 m = markets[marketIdx % MARKETS];
        borrowAmount = _bounded(borrowAmount, m.getCash());
        if (borrowAmount == 0) return;
        (bool ok, ) = address(a).call(abi.encodeWithSelector(a.borrow.selector, address(m), borrowAmount));
        if (!ok) return;
        _tick();
    }

    function actorRepay(uint8 actorIdx, uint8 marketIdx, uint256 amount) public {
        Actor a = actors[actorIdx % ACTORS];
        ICErc20 m = markets[marketIdx % MARKETS];
        MockERC20 u = underlyings[marketIdx % MARKETS];
        uint256 debt = m.borrowBalanceCurrent(address(a));
        amount = _bounded(amount, debt);
        uint256 bal = u.balanceOf(address(a));
        if (amount > bal) amount = bal;
        if (amount == 0) return;
        (bool ok, ) = address(a).call(abi.encodeWithSelector(a.repay.selector, address(m), amount));
        if (!ok) return;
        _tick();
    }

    function actorRepayBehalf(uint8 payerIdx, uint8 borrowerIdx, uint8 marketIdx, uint256 amount) public {
        Actor payer = actors[payerIdx % ACTORS];
        Actor borrower = actors[borrowerIdx % ACTORS];
        if (address(payer) == address(borrower)) return;
        ICErc20 m = markets[marketIdx % MARKETS];
        MockERC20 u = underlyings[marketIdx % MARKETS];
        uint256 debt = m.borrowBalanceCurrent(address(borrower));
        amount = _bounded(amount, debt);
        uint256 bal = u.balanceOf(address(payer));
        if (amount > bal) amount = bal;
        if (amount == 0) return;
        (bool ok, ) = address(payer).call(
            abi.encodeWithSelector(payer.repayBehalf.selector, address(m), address(borrower), amount)
        );
        if (!ok) return;
        _tick();
    }

    function actorLiquidate(
        uint8 liquidatorIdx,
        uint8 borrowerIdx,
        uint8 marketBorrowed,
        uint8 marketCollateral,
        uint256 amount
    ) public {
        Actor liqActor = actors[liquidatorIdx % ACTORS];
        Actor borrower = actors[borrowerIdx % ACTORS];
        if (address(liqActor) == address(borrower)) return;
        ICErc20 borrowed = markets[marketBorrowed % MARKETS];
        ICErc20 collateral = markets[marketCollateral % MARKETS];
        MockERC20 u = underlyings[marketBorrowed % MARKETS];

        // Bound the repay so the resulting seize never exceeds the borrower's
        // collateral balance (otherwise liquidateBorrowFresh reverts).
        uint256 exchangeRate = collateral.exchangeRateCurrent();
        if (exchangeRate == 0) return;
        uint256 maxRepay = (collateral.balanceOf(address(borrower)) * exchangeRate) / TOTAL_SEIZE_PENALTY;
        amount = _bounded(amount, maxRepay);
        uint256 debt = borrowed.borrowBalanceCurrent(address(borrower));
        if (amount > debt) amount = debt;
        uint256 bal = u.balanceOf(address(liqActor));
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        (bool ok, ) = address(liqActor).call(
            abi.encodeWithSelector(
                liqActor.liquidate.selector,
                address(borrowed),
                address(borrower),
                address(collateral),
                amount
            )
        );
        if (!ok) return;
        _tick();
    }

    function actorTransfer(uint8 fromIdx, uint8 toIdx, uint8 marketIdx, uint256 amount) public {
        Actor from = actors[fromIdx % ACTORS];
        Actor to = actors[toIdx % ACTORS];
        if (address(from) == address(to)) return;
        ICErc20 m = markets[marketIdx % MARKETS];
        amount = _bounded(amount, m.balanceOf(address(from)));
        if (amount == 0) return;
        (bool ok, ) = address(from).call(abi.encodeWithSelector(from.transfer.selector, address(m), address(to), amount));
        if (!ok) return;
        _tick();
    }

    function warpBlocks(uint256 blocks) public {
        VM.roll(block.number + (blocks % 500) + 1);
    }

    function _tick() internal {
        VM.roll(block.number + 1);
    }

    // ============================================================
    //  AddressesProvider admin actions (run3 findings coverage)
    // ============================================================

    function adminSetAddress(string calldata id, address newAddress) public {
        ap.setAddress(id, newAddress);
        _tick();
    }

    function adminSetFlywheelRewards(address rewardToken, address module, string calldata contractInterface) public {
        ap.setFlywheelRewards(rewardToken, module, contractInterface);
        _tick();
    }

    function adminSetPlugin(address asset, address plugin, string calldata contractInterface) public {
        ap.setPlugin(asset, plugin, contractInterface);
        _tick();
    }

    function adminSetRedemptionStrategy(
        address asset,
        address strategy,
        string calldata contractInterface,
        address outputToken
    ) public {
        ap.setRedemptionStrategy(asset, strategy, contractInterface, outputToken);
        _tick();
    }

    function adminSetFundingStrategy(
        address asset,
        address strategy,
        string calldata contractInterface,
        address inputToken
    ) public {
        ap.setFundingStrategy(asset, strategy, contractInterface, inputToken);
        _tick();
    }

    function adminSetBalancerPool(address inputToken, address outputToken, address pool) public {
        ap.setBalancerPoolForTokens(inputToken, outputToken, pool);
        _tick();
    }

    function adminSetPendingOwner(address newPendingOwner) public {
        ap._setPendingOwner(newPendingOwner);
        _tick();
    }

    function adminTransferOwnership(address newOwner) public {
        ap.transferOwnership(newOwner);
        _tick();
    }

    // ============================================================
    //  Invariant checks (called from the test contract)
    // ============================================================

    /// @notice cToken conservation (exact): totalSupply == sum of every actor's
    /// balance in each market. Every path (mint/redeem/transfer/seize) only
    /// mints, burns or moves cTokens against holders' balances.
    function checkCtokenConservation() external view returns (bool) {
        for (uint8 i = 0; i < MARKETS; i++) {
            uint256 sum;
            for (uint8 a = 0; a < ACTORS; a++) sum += markets[i].balanceOf(address(actors[a]));
            if (sum != markets[i].totalSupply()) return false;
        }
        return true;
    }

    /// @notice Underlying conservation (exact): per market, the sum of what
    /// actors, the market and the handler hold equals the amount minted to
    /// actors at setup. Markets burn underlying on repay, so any leak or mint
    /// breaks the equality.
    function checkUnderlyingConservation() external view returns (bool) {
        for (uint8 i = 0; i < MARKETS; i++) {
            uint256 sum = underlyings[i].balanceOf(address(this));
            for (uint8 a = 0; a < ACTORS; a++) sum += underlyings[i].balanceOf(address(actors[a]));
            sum += underlyings[i].balanceOf(address(markets[i]));
            if (sum != totalUnderlyingMinted[i]) return false;
        }
        return true;
    }

    /// @notice Borrow ledger consistency (within rounding): the sum of every
    /// actor's `borrowBalanceCurrent` matches `totalBorrowsCurrent`.
    function checkBorrowSum() external view returns (bool) {
        for (uint8 i = 0; i < MARKETS; i++) {
            uint256 sum;
            for (uint8 a = 0; a < ACTORS; a++) sum += markets[i].borrowBalanceCurrent(address(actors[a]));
            uint256 total = markets[i].totalBorrowsCurrent();
            uint256 diff = total >= sum ? total - sum : sum - total;
            if (diff > ROUNDING_TOLERANCE) return false;
        }
        return true;
    }
}
