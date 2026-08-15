// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/contracts/token/OUSD.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function roll(uint256) external;
    function warp(uint256) external;
}

// Exposes OUSD internals that production only reads internally so the
// invariant checks can pin the elastic-supply credit bookkeeping.
contract OUSDHarness is OUSD {
    function harnessSetGovernor(address g) external {
        _setGovernor(g);
    }

    function harnessCreditBalanceOf(address a) external view returns (uint256) {
        return creditBalances[a];
    }

    function harnessAlternativeCreditsPerToken(address a)
        external
        view
        returns (uint256)
    {
        return alternativeCreditsPerToken[a];
    }
}

// Handler owns the OUSD contract: it is the initial governor (initialize +
// governance actions) and the vault (mint/burn/changeSupply), mirroring how
// OriginProtocol's Vault is the privileged caller in production. Actors are
// 8 plain EOAs (0x1111...) that only ever receive tokens via mint or transfer.
contract HarvestHandler {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    OUSDHarness public ousd;

    address[8] public actors;

    uint256 public constant INITIAL_MINT = 100_000 ether;
    uint256 public constant MAX_MINT = 1_000_000 ether;

    constructor() {
        address[8] memory a = [
            address(0x1111000000000000000000000000000000000001),
            address(0x1111000000000000000000000000000000000002),
            address(0x1111000000000000000000000000000000000003),
            address(0x1111000000000000000000000000000000000004),
            address(0x1111000000000000000000000000000000000005),
            address(0x1111000000000000000000000000000000000006),
            address(0x1111000000000000000000000000000000000007),
            address(0x1111000000000000000000000000000000000008)
        ];
        for (uint256 i = 0; i < 8; i++) {
            actors[i] = a[i];
        }

        ousd = new OUSDHarness();
        ousd.harnessSetGovernor(address(this));
        ousd.initialize(address(this), 1e27);

        for (uint256 i = 0; i < 8; i++) {
            ousd.mint(actors[i], INITIAL_MINT);
        }
    }

    // Vault view required by OUSD.onlyGovernorOrStrategist for the (never
    // exercised here) non-governor path; the handler is always governor.
    function strategistAddr() external view returns (address) {
        return address(0x2222000000000000000000000000000000000001);
    }

    // ====== Actor (ERC20) actions ======

    function actorTransfer(uint8 fromIdx, uint8 toIdx, uint256 amount) public {
        address from = actors[fromIdx % 8];
        address to = actors[toIdx % 8];
        if (from == address(0) || to == address(0) || from == to) return;
        if (amount == 0) return;
        if (amount > ousd.balanceOf(from)) return;
        VM.startPrank(from);
        ousd.transfer(to, amount);
        VM.stopPrank();
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    function actorTransferFrom(
        uint8 ownerIdx,
        uint8 spenderIdx,
        uint8 toIdx,
        uint256 amount
    ) public {
        address owner = actors[ownerIdx % 8];
        address spender = actors[spenderIdx % 8];
        address to = actors[toIdx % 8];
        if (owner == address(0) || spender == address(0) || to == address(0))
            return;
        if (owner == spender || owner == to) return;
        if (amount == 0) return;
        if (amount > ousd.balanceOf(owner)) return;
        VM.startPrank(owner);
        ousd.approve(spender, amount);
        VM.stopPrank();
        VM.startPrank(spender);
        ousd.transferFrom(owner, to, amount);
        VM.stopPrank();
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    // ====== Vault actions ======

    function vaultMint(uint8 actorIdx, uint256 amount) public {
        address to = actors[actorIdx % 8];
        if (to == address(0) || amount == 0) return;
        if (amount > MAX_MINT) return;
        if (ousd.totalSupply() + amount >= type(uint128).max) return;
        ousd.mint(to, amount);
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    function vaultBurn(uint8 actorIdx, uint256 amount) public {
        address from = actors[actorIdx % 8];
        if (from == address(0) || amount == 0) return;
        if (amount > ousd.balanceOf(from)) return;
        ousd.burn(from, amount);
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    // Rebase: scale supply up/down, diluting/concentrating rebasing holders.
    function vaultChangeSupply(uint256 seed) public {
        uint256 cur = ousd.totalSupply();
        if (cur == 0) return;
        uint256 base = cur / 2;
        if (base == 0) return;
        uint256 target = base + seed % (cur + 1);
        if (target < ousd.nonRebasingSupply()) return;
        if (target == 0) return;
        ousd.changeSupply(target);
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    // ====== Rebase-opt / governance / delegation actions ======

    function actorRebaseOptIn(uint8 actorIdx) public {
        address a = actors[actorIdx % 8];
        if (a == address(0)) return;
        VM.startPrank(a);
        ousd.rebaseOptIn();
        VM.stopPrank();
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    function actorRebaseOptOut(uint8 actorIdx) public {
        address a = actors[actorIdx % 8];
        if (a == address(0)) return;
        VM.startPrank(a);
        ousd.rebaseOptOut();
        VM.stopPrank();
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    function governanceRebaseOptIn(uint8 actorIdx) public {
        address a = actors[actorIdx % 8];
        if (a == address(0)) return;
        ousd.governanceRebaseOptIn(a);
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    function delegateYield(uint8 fromIdx, uint8 toIdx) public {
        address from = actors[fromIdx % 8];
        address to = actors[toIdx % 8];
        if (from == address(0) || to == address(0) || from == to) return;
        ousd.delegateYield(from, to);
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    function undelegateYield(uint8 fromIdx) public {
        address from = actors[fromIdx % 8];
        if (from == address(0)) return;
        ousd.undelegateYield(from);
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    function warpDays(uint256 numDays) public {
        if (numDays == 0 || numDays > 365) return;
        VM.warp(block.timestamp + numDays * 1 days);
    }

    // ====== Invariant checks ======

    // No inflation: the sum of every account's reported balance can never
    // exceed the elastic total supply.
    function checkSumBalancesLeSupply() public view returns (bool) {
        uint256 sumBalances = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            if (actors[i] == address(0)) continue;
            sumBalances += ousd.balanceOf(actors[i]);
        }
        return sumBalances <= ousd.totalSupply();
    }

    // Credits conservation: the global rebasingCredits_ must exactly equal the
    // sum of creditBalances over all accounts that are NOT in the
    // alternativeCreditsPerToken (1:1, non-rebasing) bucket. YieldDelegation
    // sources carry alternativeCreditsPerToken=1e18 so they are excluded, while
    // YieldDelegation targets stay in the rebasing-credits bucket.
    function checkCreditsConservation() public view returns (bool) {
        uint256 sumCredits = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            if (actors[i] == address(0)) continue;
            if (ousd.harnessAlternativeCreditsPerToken(actors[i]) == 0) {
                sumCredits += ousd.harnessCreditBalanceOf(actors[i]);
            }
        }
        return sumCredits == ousd.rebasingCreditsHighres();
    }

    // Non-rebasing supply conservation: nonRebasingSupply must exactly equal
    // the sum of balances held by standard non-rebasing accounts (state
    // StdNonRebasing). Delegation sources hold tokens in neither bucket.
    function checkNonRebasingConservation() public view returns (bool) {
        uint256 sumNonReb = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            if (actors[i] == address(0)) continue;
            if (ousd.rebaseState(actors[i]) == OUSD.RebaseOptions.StdNonRebasing) {
                sumNonReb += ousd.balanceOf(actors[i]);
            }
        }
        return sumNonReb == ousd.nonRebasingSupply();
    }

    // Global bookkeeping sanity: non-rebasing supply is a strict component of
    // the total supply, never larger than it.
    function checkNonRebasingLeSupply() public view returns (bool) {
        return ousd.nonRebasingSupply() <= ousd.totalSupply();
    }
}
