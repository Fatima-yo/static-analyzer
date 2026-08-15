pragma solidity ^0.5.8;

import "../src/CEther.sol";
import "../src/SimpleComptroller.sol";
import "../src/SimpleInterestRateModel.sol";
import "./Actor.sol";

interface Vm {
    function roll(uint256) external;
    function warp(uint256) external;
    function deal(address, uint256) external;
}

/// @notice Invariant harness for Compound v2's CEther market (flattened
/// 0.4ddc2d... snapshot, solc 0.5.8). Two CEther markets share a permissive
/// SimpleComptroller and a WhitePaper-style SimpleInterestRateModel. The
/// handler routes every user action through 8 real Actor contracts that each
/// own their ETH and call the markets with themselves as `msg.sender`, so all
/// value transfers are ordinary atomic EVM calls. Each action rolls the block
/// so `accrueInterest` sees a positive block delta.
contract CompoundV2Handler {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint public constant ROUNDING_TOLERANCE = 1e9;

    SimpleComptroller public comptroller;
    SimpleInterestRateModel public interestRateModel;
    CEther public cethA;
    CEther public cethB;

    Actor[8] public actors;

    /// @notice total ETH in the system (actors + both markets + handler) that
    /// must be conserved by every action.
    uint public initialEth;

    constructor() public {
        for (uint256 i = 0; i < actors.length; i++) {
            actors[i] = new Actor();
            VM.deal(address(actors[i]), 1_000_000 ether);
        }

        comptroller = new SimpleComptroller();
        interestRateModel = new SimpleInterestRateModel();

        cethA = new CEther(
            ComptrollerInterface(address(comptroller)),
            InterestRateModel(address(interestRateModel)),
            0.02e18,
            "Compound Ether Market A",
            "cETH_A",
            18
        );
        cethB = new CEther(
            ComptrollerInterface(address(comptroller)),
            InterestRateModel(address(interestRateModel)),
            0.02e18,
            "Compound Ether Market B",
            "cETH_B",
            18
        );

        initialEth = 8 * 1_000_000 ether;
    }

    function _market(uint8 marketChoice) internal view returns (CEther) {
        return marketChoice % 2 == 0 ? cethA : cethB;
    }

    // ============================================================
    //  Actor actions
    // ============================================================

    function actorMint(
        uint8 actorIdx,
        uint8 marketChoice,
        uint256 amount
    ) public {
        Actor a = actors[actorIdx % 8];
        CEther c = _market(marketChoice);
        uint256 bal = address(a).balance;
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        (bool ok, ) = address(a).call(abi.encodeWithSelector(a.mint.selector, address(c), amount));
        if (!ok) return;
        _tick();
    }

    function actorRedeem(
        uint8 actorIdx,
        uint8 marketChoice,
        uint256 redeemTokens
    ) public {
        Actor a = actors[actorIdx % 8];
        CEther c = _market(marketChoice);
        uint256 bal = c.balanceOf(address(a));
        if (redeemTokens > bal) redeemTokens = bal;
        if (redeemTokens == 0) return;

        (bool ok, ) = address(a).call(abi.encodeWithSelector(a.redeem.selector, address(c), redeemTokens));
        if (!ok) return;
        _tick();
    }

    function actorBorrow(
        uint8 actorIdx,
        uint8 marketChoice,
        uint256 borrowAmount
    ) public {
        Actor a = actors[actorIdx % 8];
        CEther c = _market(marketChoice);
        uint256 cash = address(c).balance;
        if (borrowAmount > cash) borrowAmount = cash;
        if (borrowAmount == 0) return;

        (bool ok, ) = address(a).call(abi.encodeWithSelector(a.borrow.selector, address(c), borrowAmount));
        if (!ok) return;
        _tick();
    }

    function actorRepay(
        uint8 actorIdx,
        uint8 marketChoice,
        uint256 amount
    ) public {
        Actor a = actors[actorIdx % 8];
        CEther c = _market(marketChoice);
        uint256 debt = c.borrowBalanceStored(address(a));
        if (amount > debt) amount = debt;
        uint256 bal = address(a).balance;
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        (bool ok, ) = address(a).call(abi.encodeWithSelector(a.repay.selector, address(c), amount));
        if (!ok) return;
        _tick();
    }

    function actorRepayBehalf(
        uint8 payerIdx,
        uint8 borrowerIdx,
        uint8 marketChoice,
        uint256 amount
    ) public {
        Actor payer = actors[payerIdx % 8];
        Actor borrower = actors[borrowerIdx % 8];
        if (address(payer) == address(borrower)) return;
        CEther c = _market(marketChoice);
        uint256 debt = c.borrowBalanceStored(address(borrower));
        if (amount > debt) amount = debt;
        uint256 bal = address(payer).balance;
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        (bool ok, ) = address(payer).call(
            abi.encodeWithSelector(payer.repayBehalf.selector, address(c), address(borrower), amount)
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
        Actor liquidator = actors[liquidatorIdx % 8];
        Actor borrower = actors[borrowerIdx % 8];
        if (address(liquidator) == address(borrower)) return;
        CEther borrowed = _market(marketBorrowed);
        CEther collateral = _market(marketCollateral);
        if (address(borrowed) == address(collateral)) return;

        uint256 debt = borrowed.borrowBalanceStored(address(borrower));
        if (debt == 0) return;
        if (amount > debt) amount = debt;
        uint256 bal = address(liquidator).balance;
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        // skip if the borrower lacks the collateral tokens the seize would
        // need (avoid over-seize reverts that are dead fuzz weight)
        uint256 exchangeRate = collateral.exchangeRateStored();
        if (exchangeRate == 0) return;
        uint256 seizeTokens = (amount * 1.08e18) / exchangeRate;
        if (collateral.balanceOf(address(borrower)) < seizeTokens) return;

        (bool ok, ) = address(liquidator).call(
            abi.encodeWithSelector(
                liquidator.liquidate.selector,
                address(borrowed),
                address(borrower),
                address(collateral),
                amount
            )
        );
        if (!ok) return;
        _tick();
    }

    function actorTransfer(
        uint8 fromIdx,
        uint8 toIdx,
        uint8 marketChoice,
        uint256 amount
    ) public {
        Actor from = actors[fromIdx % 8];
        Actor to = actors[toIdx % 8];
        if (address(from) == address(to)) return;
        CEther c = _market(marketChoice);
        uint256 bal = c.balanceOf(address(from));
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        (bool ok, ) = address(from).call(abi.encodeWithSelector(from.transfer.selector, address(c), address(to), amount));
        if (!ok) return;
        _tick();
    }

    function actorTransferFrom(
        uint8 fromIdx,
        uint8 spenderIdx,
        uint8 toIdx,
        uint8 marketChoice,
        uint256 amount
    ) public {
        Actor from = actors[fromIdx % 8];
        Actor spender = actors[spenderIdx % 8];
        Actor to = actors[toIdx % 8];
        if (address(from) == address(to) || address(from) == address(spender)) return;
        CEther c = _market(marketChoice);
        uint256 bal = c.balanceOf(address(from));
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        (bool ok, ) = address(from).call(abi.encodeWithSelector(from.approve.selector, address(c), address(spender)));
        if (!ok) return;
        (bool ok2, ) = address(spender).call(
            abi.encodeWithSelector(spender.transferFrom.selector, address(c), address(from), address(to), amount)
        );
        if (!ok2) return;
        _tick();
    }

    function warpBlocks(uint256 blocks) public {
        _tick();
        VM.roll(block.number + (blocks % 500));
    }

    function _tick() internal {
        VM.roll(block.number + 1);
    }

    // ============================================================
    //  Invariant checks (called from the test contract)
    // ============================================================

    /// @notice cToken conservation (exact): totalSupply == sum of all holder
    /// balances. Every path (mint/redeem/transfer/seize) only moves or
    /// mints/burns cTokens against the holders' balances.
    function checkCtokenConservation() external view returns (bool) {
        return
            _ctokenSum(cethA) == cethA.totalSupply() &&
            _ctokenSum(cethB) == cethB.totalSupply();
    }

    function _ctokenSum(CEther c) internal view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += c.balanceOf(address(actors[i]));
        }
    }

    /// @notice ETH conservation (exact): the ETH held by actors + both
    /// markets + the handler equals the amount dealt at setup. Mint, borrow,
    /// repay and redeem only move ETH between these accounts.
    function checkEthConservation() external view returns (bool) {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += address(actors[i]).balance;
        }
        sum += address(cethA).balance;
        sum += address(cethB).balance;
        sum += address(this).balance;
        return sum == initialEth;
    }

    /// @notice borrow ledger consistency (within rounding): the sum of every
    /// borrower's `borrowBalanceStored` matches `totalBorrows`. Per-borrower
    /// truncation in principal*borrowIndex/interestIndex can drift a few wei
    /// per account per accrual.
    function checkBorrowSum() external view returns (bool) {
        return
            _borrowSum(cethA, cethA.totalBorrows()) &&
            _borrowSum(cethB, cethB.totalBorrows());
    }

    function _borrowSum(CEther c, uint256 total) internal view returns (bool) {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += c.borrowBalanceStored(address(actors[i]));
        }
        uint256 diff = total >= sum ? total - sum : sum - total;
        return diff <= ROUNDING_TOLERANCE;
    }
}
