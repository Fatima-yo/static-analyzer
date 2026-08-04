// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../src/core/Core.sol";
import "../src/tokens/CreditToken.sol";
import "../src/tokens/GuildToken.sol";
import "../src/governance/ProfitManager.sol";
import "../src/loan/LendingTerm.sol";
import "../src/loan/AuctionHouse.sol";
import "../src/rate-limits/RateLimitedMinter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface Vm {
    function roll(uint256) external;
    function warp(uint256) external;
    function startPrank(address) external;
    function stopPrank() external;
}

/// @notice simple 18-decimal collateral token (stands in for WETH etc.)
contract CollateralToken is ERC20 {
    constructor() ERC20("Collateral", "COLL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Invariant harness for the Ethereum Credit Guild (ECG) v1.6-era
/// code vendored from the run1 full-code snapshot.
///
/// The handler plays governor + role-admin of the whole system and routes
/// every user action through 8 actors. All protocol roles (GAUGE_PNL_NOTIFIER,
/// CREDIT_MINTER/BURNER, RATE_LIMITED_CREDIT_MINTER) are granted to the
/// protocol contracts, mirroring production wiring.
contract CreditGuildHandler {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 public constant ROUNDING_TOLERANCE = 1e6;

    Core public core;
    CreditToken public credit;
    GuildToken public guild;
    ProfitManager public profitManager;
    RateLimitedMinter public rateLimitedMinter;
    AuctionHouse public auctionHouse;
    CollateralToken public collateral;

    LendingTerm public term0;
    LendingTerm public term1;

    address[8] public actors;

    bytes32[] public loanIds;
    mapping(bytes32 => LendingTerm) public termOfLoan;

    /// @notice collateral of loans closed with no collateral movement
    /// (auctionHouse.forgive): it stays on the term, out of open-loan sum.
    uint256 public stuckCollateral;

    bytes32 internal constant RATE_LIMITED_CREDIT_MINTER_ROLE =
        keccak256("RATE_LIMITED_CREDIT_MINTER_ROLE");
    bytes32 internal constant CREDIT_MINTER_ROLE = keccak256("CREDIT_MINTER_ROLE");
    bytes32 internal constant CREDIT_BURNER_ROLE = keccak256("CREDIT_BURNER_ROLE");
    bytes32 internal constant GUILD_MINTER_ROLE = keccak256("GUILD_MINTER_ROLE");
    bytes32 internal constant GAUGE_ADD_ROLE = keccak256("GAUGE_ADD_ROLE");
    bytes32 internal constant GAUGE_PARAMETERS_ROLE =
        keccak256("GAUGE_PARAMETERS_ROLE");
    bytes32 internal constant GAUGE_PNL_NOTIFIER_ROLE =
        keccak256("GAUGE_PNL_NOTIFIER_ROLE");

    constructor() {
        actors = [
            0x1111000000000000000000000000000000000001,
            0x1111000000000000000000000000000000000002,
            0x1111000000000000000000000000000000000003,
            0x1111000000000000000000000000000000000004,
            0x1111000000000000000000000000000000000005,
            0x1111000000000000000000000000000000000006,
            0x1111000000000000000000000000000000000007,
            0x1111000000000000000000000000000000000008
        ];

        core = new Core();
        credit = new CreditToken(address(core), "Credit", "CREDIT");
        guild = new GuildToken(address(core));
        profitManager = new ProfitManager(address(core));
        collateral = new CollateralToken();
        rateLimitedMinter = new RateLimitedMinter(
            address(core),
            address(credit),
            RATE_LIMITED_CREDIT_MINTER_ROLE,
            1e18, // max rate limit per second (governance bound)
            uint128(1e16), // starting rate limit per second
            uint128(1e27) // buffer cap
        );
        auctionHouse = new AuctionHouse(address(core), 650, 1800, 0);

        // handler holds admin powers
        core.grantRole(CREDIT_MINTER_ROLE, address(this));
        core.grantRole(CREDIT_BURNER_ROLE, address(this));
        core.grantRole(GUILD_MINTER_ROLE, address(this));
        core.grantRole(GAUGE_ADD_ROLE, address(this));
        core.grantRole(GAUGE_PARAMETERS_ROLE, address(this));
        core.grantRole(RATE_LIMITED_CREDIT_MINTER_ROLE, address(rateLimitedMinter));
        core.grantRole(CREDIT_MINTER_ROLE, address(rateLimitedMinter));
        // ProfitManager mints/burns CREDIT when settling PnL
        core.grantRole(CREDIT_MINTER_ROLE, address(profitManager));
        core.grantRole(CREDIT_BURNER_ROLE, address(profitManager));

        profitManager.initializeReferences(address(credit), address(guild));
        // default tolerance (120%) with a 50/50 gauge split caps each term at
        // 60% of total issuance, so a 2nd loan on the same term always reverts
        // "debt ceiling reached". 200% keeps the balanced harness productive.
        profitManager.setGaugeWeightTolerance(2e18);

        // LendingTerms are deployed behind EIP-1167 clones because the
        // implementation's constructor bakes core=address(1) and `initialize`
        // asserts the proxy's core slot is 0.
        LendingTerm implementation = new LendingTerm();
        term0 = LendingTerm(_clone(address(implementation)));
        term1 = LendingTerm(_clone(address(implementation)));

        LendingTerm.LendingTermReferences memory refs = LendingTerm
            .LendingTermReferences({
                profitManager: address(profitManager),
                guildToken: address(guild),
                auctionHouse: address(auctionHouse),
                creditMinter: address(rateLimitedMinter),
                creditToken: address(credit)
            });
        LendingTerm.LendingTermParams memory params = LendingTerm
            .LendingTermParams({
                collateralToken: address(collateral),
                maxDebtPerCollateralToken: 1e18,
                interestRate: 0.05e18,
                maxDelayBetweenPartialRepay: 0,
                minPartialRepayPercent: 0,
                openingFee: 0,
                hardCap: 1e30
            });
        term0.initialize(address(core), refs, abi.encode(params));
        term1.initialize(address(core), refs, abi.encode(params));

        // wire lending terms to core roles
        core.grantRole(GAUGE_PNL_NOTIFIER_ROLE, address(term0));
        core.grantRole(CREDIT_MINTER_ROLE, address(term0));
        core.grantRole(CREDIT_BURNER_ROLE, address(term0));
        core.grantRole(RATE_LIMITED_CREDIT_MINTER_ROLE, address(term0));
        core.grantRole(GAUGE_PNL_NOTIFIER_ROLE, address(term1));
        core.grantRole(CREDIT_MINTER_ROLE, address(term1));
        core.grantRole(CREDIT_BURNER_ROLE, address(term1));
        core.grantRole(RATE_LIMITED_CREDIT_MINTER_ROLE, address(term1));

        // both terms are gauges; transfers of GUILD enabled
        guild.addGauge(0, address(term0));
        guild.addGauge(0, address(term1));
        guild.enableTransfer();
        guild.setMaxGauges(10);

        // seed funds
        for (uint256 i = 0; i < actors.length; i++) {
            credit.mint(actors[i], 100_000 ether);
            guild.mint(actors[i], 100_000 ether);
            collateral.mint(actors[i], 1_000_000 ether);
        }

        // seed gauge weights: each actor 25k GUILD to each term => 50/50 split
        for (uint256 i = 0; i < actors.length; i++) {
            VM.startPrank(actors[i]);
            guild.incrementGauge(address(term0), 25_000 ether);
            guild.incrementGauge(address(term1), 25_000 ether);
            VM.stopPrank();
        }

        // all actors start rebasing
        for (uint256 i = 0; i < actors.length; i++) {
            VM.startPrank(actors[i]);
            credit.enterRebase();
            VM.stopPrank();
        }
    }

    // ============================================================
    //  Actor actions
    // ============================================================

    function actorBorrow(
        uint8 actorIdx,
        uint8 termChoice,
        uint256 borrowAmount,
        uint256 collateralAmount
    ) public {
        address actor = actors[actorIdx % 8];
        LendingTerm term = termChoice % 2 == 0 ? term0 : term1;

        borrowAmount = 100e18 + (borrowAmount % 1e22);
        collateralAmount =
            borrowAmount +
            (collateralAmount % borrowAmount) +
            1e18;
        uint256 bal = collateral.balanceOf(actor);
        if (collateralAmount > bal) {
            collateralAmount = bal;
            if (collateralAmount < borrowAmount) return;
        }

        VM.startPrank(actor);
        collateral.approve(address(term), type(uint256).max);
        bytes32 id = term.borrow(borrowAmount, collateralAmount);
        VM.stopPrank();

        loanIds.push(id);
        termOfLoan[id] = term;
        _tick();
    }

    function actorAddCollateral(
        uint8 actorIdx,
        uint256 loanIdxSeed,
        uint256 amount
    ) public {
        bytes32 id = _pickLoan(loanIdxSeed);
        if (id == bytes32(0)) return;
        address actor = actors[actorIdx % 8];
        LendingTerm term = termOfLoan[id];

        uint256 bal = collateral.balanceOf(actor);
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        VM.startPrank(actor);
        collateral.approve(address(term), type(uint256).max);
        term.addCollateral(id, amount);
        VM.stopPrank();
        _tick();
    }

    function actorPartialRepay(
        uint8 actorIdx,
        uint256 loanIdxSeed,
        uint256 amount
    ) public {
        bytes32 id = _pickLoan(loanIdxSeed);
        if (id == bytes32(0)) return;
        address actor = actors[actorIdx % 8];
        LendingTerm term = termOfLoan[id];

        VM.startPrank(actor);
        credit.approve(address(term), type(uint256).max);
        term.partialRepay(id, amount);
        VM.stopPrank();
        _tick();
    }

    function actorRepay(uint8 actorIdx, uint256 loanIdxSeed) public {
        bytes32 id = _pickLoan(loanIdxSeed);
        if (id == bytes32(0)) return;
        address actor = actors[actorIdx % 8];
        LendingTerm term = termOfLoan[id];

        VM.startPrank(actor);
        credit.approve(address(term), type(uint256).max);
        term.repay(id);
        VM.stopPrank();
        _tick();
    }

    function actorCall(uint8 actorIdx, uint256 loanIdxSeed) public {
        bytes32 id = _pickLoan(loanIdxSeed);
        if (id == bytes32(0)) return;
        address actor = actors[actorIdx % 8];
        LendingTerm term = termOfLoan[id];

        VM.startPrank(actor);
        term.call(id);
        VM.stopPrank();
        _tick();
    }

    function actorBid(uint8 actorIdx, uint256 loanIdxSeed) public {
        bytes32 id = _pickLoan(loanIdxSeed);
        if (id == bytes32(0)) return;
        address actor = actors[actorIdx % 8];
        LendingTerm term = termOfLoan[id];

        VM.startPrank(actor);
        credit.approve(address(term), type(uint256).max);
        auctionHouse.bid(id);
        VM.stopPrank();
        _tick();
    }

    function actorForgive(uint8 actorIdx, uint256 loanIdxSeed) public {
        bytes32 id = _pickLoan(loanIdxSeed);
        if (id == bytes32(0)) return;
        address actor = actors[actorIdx % 8];

        // record collateral that will remain stuck on the term if the
        // forgive succeeds (getBidDetail reverts if not forgiving yet)
        LendingTerm.Loan memory loan = termOfLoan[id].getLoan(id);
        VM.startPrank(actor);
        auctionHouse.forgive(id);
        VM.stopPrank();
        stuckCollateral += loan.collateralAmount;
        _tick();
    }

    function actorDonateSurplus(
        uint8 actorIdx,
        uint256 amount
    ) public {
        address actor = actors[actorIdx % 8];
        uint256 bal = credit.balanceOf(actor);
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        VM.startPrank(actor);
        credit.approve(address(profitManager), type(uint256).max);
        profitManager.donateToSurplusBuffer(amount);
        VM.stopPrank();
        _tick();
    }

    function actorIncrementGauge(
        uint8 actorIdx,
        uint8 termChoice,
        uint256 weight
    ) public {
        address actor = actors[actorIdx % 8];
        address termAddr = termChoice % 2 == 0 ? address(term0) : address(term1);
        uint256 free = guild.userUnusedWeight(actor);
        if (weight > free) weight = free;
        if (weight == 0) return;

        VM.startPrank(actor);
        guild.incrementGauge(termAddr, weight);
        VM.stopPrank();
        _tick();
    }

    function actorDecrementGauge(
        uint8 actorIdx,
        uint8 termChoice,
        uint256 weight
    ) public {
        address actor = actors[actorIdx % 8];
        address termAddr = termChoice % 2 == 0 ? address(term0) : address(term1);
        uint256 allocated = guild.getUserGaugeWeight(actor, termAddr);
        if (weight > allocated) weight = allocated;
        if (weight == 0) return;

        VM.startPrank(actor);
        guild.decrementGauge(termAddr, weight);
        VM.stopPrank();
        _tick();
    }

    function actorTransferGuild(
        uint8 fromIdx,
        uint8 toIdx,
        uint256 amount
    ) public {
        address from = actors[fromIdx % 8];
        address to = actors[toIdx % 8];
        if (from == to) return;
        uint256 bal = guild.balanceOf(from);
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        VM.startPrank(from);
        guild.transfer(to, amount);
        VM.stopPrank();
        _tick();
    }

    function actorTransferCredit(
        uint8 fromIdx,
        uint8 toIdx,
        uint256 amount
    ) public {
        address from = actors[fromIdx % 8];
        address to = actors[toIdx % 8];
        if (from == to) return;
        uint256 bal = credit.balanceOf(from);
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        VM.startPrank(from);
        credit.transfer(to, amount);
        VM.stopPrank();
        _tick();
    }

    function actorTransferCollateral(
        uint8 fromIdx,
        uint8 toIdx,
        uint256 amount
    ) public {
        address from = actors[fromIdx % 8];
        address to = actors[toIdx % 8];
        if (from == to) return;
        uint256 bal = collateral.balanceOf(from);
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        VM.startPrank(from);
        collateral.transfer(to, amount);
        VM.stopPrank();
        _tick();
    }

    function actorApplyLoss(uint8 actorIdx, uint8 termChoice) public {
        address actor = actors[actorIdx % 8];
        address termAddr = termChoice % 2 == 0 ? address(term0) : address(term1);
        if (guild.lastGaugeLoss(termAddr) == 0) return;

        VM.startPrank(actor);
        guild.applyGaugeLoss(termAddr, actor);
        VM.stopPrank();
        _tick();
    }

    function actorClaimRewards(uint8 actorIdx) public {
        address actor = actors[actorIdx % 8];
        VM.startPrank(actor);
        profitManager.claimRewards(actor);
        VM.stopPrank();
        _tick();
    }

    function actorEnterRebase(uint8 actorIdx) public {
        address actor = actors[actorIdx % 8];
        if (credit.isRebasing(actor)) return;
        VM.startPrank(actor);
        credit.enterRebase();
        VM.stopPrank();
        _tick();
    }

    function actorExitRebase(uint8 actorIdx) public {
        address actor = actors[actorIdx % 8];
        if (!credit.isRebasing(actor)) return;
        VM.startPrank(actor);
        credit.exitRebase();
        VM.stopPrank();
        _tick();
    }

    function warpDays(uint256 days_) public {
        _tick();
        VM.warp(block.timestamp + (days_ % 31) * 1 days);
    }

    function _pickLoan(uint256 loanIdxSeed) internal view returns (bytes32 id) {
        if (loanIds.length == 0) return bytes32(0);
        id = loanIds[loanIdxSeed % loanIds.length];
        LendingTerm.Loan memory loan = termOfLoan[id].getLoan(id);
        // closed (repaid or forgiven) loans cannot be acted upon
        if (loan.closeTime != 0 || loan.borrowTime == 0) return bytes32(0);
    }

    function _tick() internal {
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    // ============================================================
    //  Invariant checks (called from the test contract)
    // ============================================================

    /// @notice CREDIT is conserved: sum of balances across every account that
    /// can hold it equals totalSupply, within rebase rounding tolerance.
    function checkCreditConservation() external view returns (bool) {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += credit.balanceOf(actors[i]);
        }
        sum += credit.balanceOf(address(this));
        sum += credit.balanceOf(address(term0));
        sum += credit.balanceOf(address(term1));
        sum += credit.balanceOf(address(profitManager));
        sum += credit.balanceOf(address(auctionHouse));
        sum += credit.balanceOf(address(rateLimitedMinter));

        uint256 supply = credit.totalSupply();
        uint256 diff = supply >= sum ? supply - sum : sum - supply;
        return diff <= ROUNDING_TOLERANCE;
    }

    /// @notice GUILD is conserved between actors (plain ERC20, no rebase).
    function checkGuildConservation() external view returns (bool) {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += guild.balanceOf(actors[i]);
        }
        sum += guild.balanceOf(address(this));
        return sum == guild.totalSupply();
    }

    /// @notice gauge weight accounting never loses a wei:
    /// user sums == gauge weight (live + deprecated),
    /// live-gauge sums == totalWeight / totalTypeWeight,
    /// user totals == sum of their per-gauge weights.
    function checkGaugeWeightConservation() external view returns (bool) {
        address[] memory gauges = guild.gauges();

        for (uint256 g = 0; g < gauges.length; g++) {
            uint256 userSum;
            for (uint256 i = 0; i < actors.length; i++) {
                userSum += guild.getUserGaugeWeight(actors[i], gauges[g]);
            }
            if (userSum != guild.getGaugeWeight(gauges[g])) return false;
        }

        address[] memory live = guild.liveGauges();
        uint256 total;
        uint256 typeTotal;
        for (uint256 g = 0; g < live.length; g++) {
            uint256 w = guild.getGaugeWeight(live[g]);
            total += w;
            if (guild.gaugeType(live[g]) == 0) typeTotal += w;
        }
        if (total != guild.totalWeight()) return false;
        if (typeTotal != guild.totalTypeWeight(0)) return false;

        for (uint256 i = 0; i < actors.length; i++) {
            uint256 userTotal;
            for (uint256 g = 0; g < gauges.length; g++) {
                userTotal += guild.getUserGaugeWeight(actors[i], gauges[g]);
            }
            if (userTotal != guild.getUserWeight(actors[i])) return false;
        }
        return true;
    }

    /// @notice CREDIT votes received by all delegatees == votes delegated by
    /// all delegators (only actors participate).
    function checkVotesConservation() external view returns (bool) {
        uint256 delegated;
        uint256 received;
        for (uint256 i = 0; i < actors.length; i++) {
            delegated += credit.userDelegatedVotes(actors[i]);
            received += credit.getVotes(actors[i]);
        }
        return delegated == received;
    }

    /// @notice collateral deposited in the terms equals the sum of collateral
    /// backing still-open loans, plus collateral stuck by forgiven auctions.
    function checkCollateralConservation() external view returns (bool) {
        uint256 openCollateral;
        for (uint256 i = 0; i < loanIds.length; i++) {
            LendingTerm.Loan memory loan = termOfLoan[loanIds[i]].getLoan(
                loanIds[i]
            );
            if (loan.closeTime == 0) {
                openCollateral += loan.collateralAmount;
            }
        }
        uint256 termBalance = collateral.balanceOf(address(term0)) +
            collateral.balanceOf(address(term1));
        return termBalance == openCollateral + stuckCollateral;
    }

    /// @notice the ProfitManager's issuance ledger always matches the terms.
    function checkIssuanceConsistency() external view returns (bool) {
        return
            profitManager.totalIssuance() == term0.issuance() + term1.issuance();
    }

    /// @notice issuance stays within per-term hard caps and global max.
    function checkIssuanceWithinCaps() external view returns (bool) {
        return
            term0.issuance() <= term0.getParameters().hardCap &&
            term1.issuance() <= term1.getParameters().hardCap &&
            profitManager.totalIssuance() <= profitManager.maxTotalIssuance();
    }

    // ============================================================
    //  internals
    // ============================================================

    /// @notice minimal proxy (EIP-1167) clone. 55-byte initcode layout:
    /// [0x00,0x0a) init, [0x0a,0x14) runtime prefix, [0x14,0x28) impl
    /// address, [0x28,0x37) runtime suffix.
    function _clone(address implementation) internal returns (address instance) {
        bytes memory init = bytes.concat(
            hex"3d602d80600a3d3981f3",
            hex"363d3d373d3d3d363d73",
            abi.encodePacked(implementation),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        assembly {
            instance := create(0, add(init, 0x20), mload(init))
        }
        require(instance != address(0), "clone failed");
    }
}
