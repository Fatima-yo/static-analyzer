// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;

import "../src/contract/contract/token/RocketTokenRETH.sol";
import "../src/contract/contract/RocketBase.sol";

import "./MockStorage.sol";
import "./MockDepositPool.sol";
import "./MockNetworkBalances.sol";
import "./MockDAOProtocolSettingsNetwork.sol";
import "./Actor.sol";

interface Vm {
    function deal(address, uint256) external;
    function roll(uint256) external;
    function warp(uint256) external;
    function expectRevert(bytes calldata) external;
}

/// @notice Invariant harness for Rocket Pool's RocketTokenRETH (Ethereum
/// 0xae78..., solc 0.7.6). Models the full backing system: a deposit pool that
/// holds liquid ETH, a validator account holding staking ETH, and a network
/// balances oracle that only ever receives *honest* reports. Eight Actor
/// contracts hold rETH + ETH and route every value-bearing operation with
/// themselves as `msg.sender`, so all transfers are ordinary atomic EVM
/// transfers (no prank-based balance redirection, which leaks ETH under
/// foundry's call_raw + prank+value path). mint() is only ever called against
/// freshly deposited ETH (as the real deposit pool does), so any break of the
/// backing invariant is attributable to contract code, not oracle manipulation.
contract RocketHandler {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 public constant DEPOSIT_DELAY = 10;
    uint256 public constant TARGET_COLLATERAL_RATE = 0.9 ether;
    uint256 public constant SEED_BACKING = 2000 ether;
    uint256 public constant ACTOR_ETH = 100 ether;
    uint256 public constant CONSERVATION_CONSTANT = SEED_BACKING + 8 * ACTOR_ETH;

    address payable public constant VALIDATOR = address(uint160(0x1111111111111111111111111111111111119999));

    MockStorage public storageC;
    MockDepositPool public depositPool;
    MockNetworkBalances public oracle;
    MockDAOProtocolSettingsNetwork public settings;
    RocketTokenRETH public reth;

    address payable[8] public actors;

    constructor() {
        storageC = new MockStorage(address(0), address(0), address(0), DEPOSIT_DELAY);
        depositPool = new MockDepositPool(storageC, VALIDATOR);
        oracle = new MockNetworkBalances();
        settings = new MockDAOProtocolSettingsNetwork(TARGET_COLLATERAL_RATE);
        reth = new RocketTokenRETH(storageC);

        storageC.setContractAddress("rocketDepositPool", address(depositPool));
        storageC.setContractAddress("rocketNetworkBalances", address(oracle));
        storageC.setContractAddress("rocketDAOProtocolSettingsNetwork", address(settings));

        for (uint256 i = 0; i < 8; ++i) {
            actors[i] = payable(address(new Actor()));
            VM.deal(actors[i], ACTOR_ETH);
        }
        VM.deal(address(this), SEED_BACKING);

        depositPool.deposit{value: SEED_BACKING}();
        for (uint256 i = 0; i < 8; ++i) {
            depositPool.mintReth(reth, SEED_BACKING / 8, address(actors[i]));
        }
        updateBalances();
        VM.warp(block.timestamp + 1000);
    }

    /// Deterministic bounding: values already in [min, max] are preserved
    /// (so explicit smoke-test amounts survive), out-of-range fuzz inputs are
    /// mapped into the range via modulo.
    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        if (x >= min && x <= max) return x;
        return min + x % (max - min + 1);
    }

    function realBacking() public view returns (uint256) {
        return address(reth).balance + address(depositPool).balance + VALIDATOR.balance;
    }

    /// Route an action through an Actor and surface any protocol revert (the
    /// deposit-delay / liquidity guards) instead of swallowing it.
    function _route(Actor actor, bytes memory payload) internal {
        (bool ok, bytes memory data) = address(actor).call(payload);
        if (!ok) {
            if (data.length > 0) {
                assembly {
                    revert(add(data, 32), mload(data))
                }
            }
            revert("actor call failed");
        }
    }

    /// Advance the chain past the deposit-delay window before a routed action.
    /// The real protocol's `_beforeTokenTransfer` guard requires
    /// `block.number - lastDepositBlock > depositDelay` after a deposit;
    /// without advancing the block, post-deposit burns/transfers revert. The
    /// invariant fuzzer commits state even for reverted calls (foundry
    /// foundry_invariant.rs:547), which corrupts actor balances under
    /// reverts, so the harness models the passage of time instead of relying
    /// on reverts.
    function _tick() internal {
        VM.roll(block.number + DEPOSIT_DELAY + 1);
    }

    function deposit(uint256 idx, uint256 amount) external {
        _tick();
        Actor actor = Actor(actors[idx % 8]);
        uint256 bal = actors[idx % 8].balance;
        if (bal == 0) return;
        uint256 a = _bound(amount, 1, bal);
        _route(actor, abi.encodeWithSelector(Actor.deposit.selector, address(depositPool), a));
        emitDeltas("deposit");
    }

    function depositAndMint(uint256 idx, uint256 amount) external {
        _tick();
        Actor actor = Actor(actors[idx % 8]);
        uint256 bal = actors[idx % 8].balance;
        if (bal == 0) return;
        uint256 a = _bound(amount, 1, bal);
        _route(actor, abi.encodeWithSelector(Actor.depositAndMint.selector, address(depositPool), address(reth), a));
        emitDeltas("depositAndMint");
    }

    function burn(uint256 idx, uint256 amount) external {
        _tick();
        Actor actor = Actor(actors[idx % 8]);
        uint256 bal = reth.balanceOf(actors[idx % 8]);
        if (bal == 0) return;
        uint256 a = _bound(amount, 1, bal);
        _route(actor, abi.encodeWithSelector(Actor.burn.selector, address(reth), a));
        emitDeltas("burn");
    }

    function transfer(uint256 fromIdx, uint256 toIdx, uint256 amount) external {
        _tick();
        Actor from = Actor(actors[fromIdx % 8]);
        Actor to = Actor(actors[toIdx % 8]);
        uint256 bal = reth.balanceOf(actors[fromIdx % 8]);
        if (bal == 0) return;
        uint256 a = _bound(amount, 1, bal);
        _route(from, abi.encodeWithSelector(Actor.transfer.selector, address(reth), address(to), a));
        emitDeltas("transfer");
    }

    function stake(uint256 amount) external {
        uint256 bal = address(depositPool).balance;
        if (bal == 0) return;
        uint256 a = _bound(amount, 1, bal);
        depositPool.assignToValidator(a);
        emitDeltas("stake");
    }

    function updateBalances() public {
        uint256 total = address(reth).balance + address(depositPool).balance + VALIDATOR.balance;
        oracle.submitBalances(block.number, total, VALIDATOR.balance, reth.totalSupply());
        emitDeltas("updateBalances");
    }

    function advanceBlocks(uint256 n) external {
        uint256 steps = _bound(n, 1, 50);
        VM.roll(block.number + steps);
    }

    function depositExcess(uint256 amount) external {
        uint256 bal = address(depositPool).balance;
        if (bal == 0) return;
        uint256 a = _bound(amount, 1, bal);
        depositPool.depositExcessReth(reth, a);
        emitDeltas("depositExcess");
    }

    function depositExcessCollateral() external {
        reth.depositExcessCollateral();
        emitDeltas("depositExcessCollateral");
    }

    function checkBacking() external view returns (bool) {
        return reth.getEthValue(reth.totalSupply()) <= realBacking();
    }

    function checkCollateralRate() external view returns (bool) {
        return reth.getCollateralRate() <= 1 ether;
    }

    function checkEthConservation() public view returns (bool) {
        uint256 sum;
        for (uint256 i = 0; i < 8; ++i) {
            sum += actors[i].balance;
        }
        sum += address(this).balance;
        sum += address(reth).balance + address(depositPool).balance + VALIDATOR.balance;
        return sum == CONSERVATION_CONSTANT;
    }

    event DebugDeltas(uint256 pool, uint256 rethBal, uint256 val, uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4, uint256 a5, uint256 a6, uint256 a7, uint256 sum, string action);

    function emitDeltas(string memory action) internal {
        uint256 s;
        for (uint256 i = 0; i < 8; ++i) {
            s += actors[i].balance;
        }
        s += address(this).balance;
        s += address(reth).balance + address(depositPool).balance + VALIDATOR.balance;
        emit DebugDeltas(
            address(depositPool).balance, address(reth).balance, VALIDATOR.balance,
            actors[0].balance, actors[1].balance, actors[2].balance, actors[3].balance,
            actors[4].balance, actors[5].balance, actors[6].balance, actors[7].balance, s, action
        );
    }

    function assertConserved(string memory action) internal view {
        if (!checkEthConservation()) {
            revert(string(abi.encodePacked("CONSERVATION BREAK after ", action)));
        }
    }

    function conservationBreakdown() external view returns (uint256 sum, uint256 constant_, uint256 actorSum, uint256 handler, uint256 rethBal, uint256 poolBal, uint256 validatorBal) {
        uint256 actorSum_;
        for (uint256 i = 0; i < 8; ++i) {
            actorSum_ += actors[i].balance;
        }
        return (
            actorSum_ + address(this).balance + address(reth).balance + address(depositPool).balance + VALIDATOR.balance,
            CONSERVATION_CONSTANT,
            actorSum_,
            address(this).balance,
            address(reth).balance,
            address(depositPool).balance,
            VALIDATOR.balance
        );
    }

    function actorBalances() external view returns (uint256[8] memory) {
        uint256[8] memory bals;
        for (uint256 i = 0; i < 8; ++i) {
            bals[i] = actors[i].balance;
        }
        return bals;
    }

    function checkRethSupply() external view returns (bool) {
        uint256 sum;
        for (uint256 i = 0; i < 8; ++i) {
            sum += reth.balanceOf(actors[i]);
        }
        sum += reth.balanceOf(address(this));
        return reth.totalSupply() == sum;
    }
}
