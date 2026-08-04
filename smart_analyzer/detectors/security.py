"""
Security vulnerability detectors.

This module provides detectors for critical security vulnerabilities
that could lead to exploits or loss of funds.

The detectors reason at the function/contract level using the project-wide
``AnalyzerContext`` (see ``smart_analyzer/context.py``) rather than matching
raw AST node patterns, which eliminates the degenerate false-positive behavior
of the previous implementations.
"""

from typing import Dict, Any, List
import re

from ..utils import detector, parse_src
from ..findings import (
    AccessControlFinding, FlashLoanFinding, FrontRunningFinding,
    TimestampFinding, DelegateCallFinding, UninitializedFinding,
    ZeroAddressFinding, MEVFinding, StorageCollisionFinding,
    UpgradeFinding, CrossChainFinding, BadRandomnessFinding, DoSFinding, Severity
)
from ..context import (
    get_analysis_context, walk_nodes, node_is, ident_name, index_base,
    index_value, low_level_call_member, call_target, _expr_contains_this,
    function_has_zero_check, collect_written_state_names, timestamp_uses,
    _is_constant_var, function_is_sensitive, function_reentrancy_guarded,
    _reads_price, _moves_tokens, function_has_mev_protection,
    bad_randomness_uses, bin_operand, _target_refs_state, _write_target_name,
    _ts_use_benign, timestamp_uses,
)

UPGRADE_NAME_TOKENS = ("upgrade", "setimplementation", "changeimplementation",
                       "updateimplementation", "setimpl", "changesimpl")

OWNER_TOKENS = ("owner", "creator", "admin", "operator", "controller",
                "manager", "govern", "pendingowner", "pendingadmin")

_FLASH_CALLBACK_RE = re.compile(r"(receiveflash|onflash|callback|executeoperation|flashcall)")


def _is_public_external(node: Dict[str, Any]) -> bool:
    return node.get("visibility") in ("public", "external")


def _is_view_pure(node: Dict[str, Any]) -> bool:
    return node.get("stateMutability") in ("view", "pure")


def _parse_line(node: Dict[str, Any], file_path: str) -> Any:
    return parse_src(node.get("src"), file_path)


def _writes_ownership_state(ctx, cinfo, node, _seen=None) -> bool:
    """True if the function (or an internal function it calls) writes a state var
    whose name carries an ownership token, without that write being per-user."""
    from ..context import _write_target_name, _write_is_per_user, _internal_call_target
    if _seen is None:
        _seen = set()
    nid = node.get("id")
    if nid is not None:
        if nid in _seen:
            return False
        _seen.add(nid)
    for n in walk_nodes(node.get("body")):
        nt = n.get("nodeType")
        if nt == "FunctionCall":
            tgt = _internal_call_target(n, cinfo, ctx)
            if tgt is not None and _writes_ownership_state(ctx, cinfo, tgt, _seen):
                return True
            continue
        if nt not in ("Assignment", "UnaryOperation", "DeleteStatement"):
            continue
        if _write_is_per_user(n):
            continue
        name = _write_target_name(n, cinfo)
        if name and any(tok in name.lower() for tok in OWNER_TOKENS):
            return True
    return False


def _calls_selfdestruct(body) -> bool:
    for n in walk_nodes(body):
        if not node_is(n, "FunctionCall"):
            continue
        ex = n.get("expression", {})
        nm = (ex.get("memberName") or ex.get("name") or "").lower()
        if nm in ("selfdestruct", "suicide"):
            return True
    return False


def _per_user_balance_read(expr, cinfo) -> bool:
    """True if ``expr`` reads a per-``msg.sender`` balance from a state mapping
    (e.g. ``balances[msg.sender]`` / ``balanceOf[msg.sender]``)."""
    if not node_is(expr, "IndexAccess"):
        return False
    base = index_base(expr)
    name = ident_name(base)
    if not name or name not in cinfo.state_var_names:
        return False
    if "balance" not in name.lower() and name.lower() not in ("refunds", "credit", "credits"):
        return False
    from ..context import _expr_mentions_msg_sender
    return _expr_mentions_msg_sender(index_value(expr))


def _payout_without_balance_update(ctx, cinfo, node) -> bool:
    """True if the function pays out a ``balances[msg.sender]``-style amount but
    never updates that balance mapping (the balance is not cleared/subtracted)."""
    body = node.get("body")
    written_bases = set()
    for n in walk_nodes(body):
        if n.get("nodeType") in ("Assignment", "UnaryOperation", "DeleteStatement"):
            name = _write_target_name(n, cinfo)
            if name:
                written_bases.add(name)
    for n in walk_nodes(body):
        if not node_is(n, "FunctionCall"):
            continue
        ex = n.get("expression", {})
        m = ex.get("memberName") if node_is(ex, "MemberAccess") else ex.get("name")
        if (m or "").lower() not in ("transfer", "send"):
            continue
        args = n.get("arguments", []) or []
        for arg in args:
            if _per_user_balance_read(arg, cinfo):
                base = ident_name(index_base(arg))
                if base and base not in written_bases:
                    return True
    return False


def _confused_sign_withdraw(ctx, cinfo, node) -> bool:
    """True if a withdrawal function guards ``require(amount >= balance[msg.sender])``
    -- the inverted comparison lets the caller withdraw more than they hold."""
    params = {p.get("name") for p in (node.get("parameters", {}).get("parameters", []) or [])}
    body = node.get("body")
    if not any(tok in (node.get("name") or "").lower()
               for tok in ("withdraw", "transfer", "redeem", "claim", "refund", "cashout")):
        return False
    for n in walk_nodes(body):
        if not node_is(n, "BinaryOperation"):
            continue
        if n.get("operator") not in (">=", ">"):
            continue
        left = bin_operand(n, "left")
        right = bin_operand(n, "right")
        if left is None or right is None:
            continue
        from ..context import _expr_mentions_msg_sender
        if _per_user_balance_read(right, cinfo) and _expr_mentions_msg_sender(index_value(right)):
            left_names = {sub.get("name") for sub in walk_nodes(left) if node_is(sub, "Identifier")}
            if left_names & params:
                return True
    return False


@detector("access_control", "🔐 Access Control", "Detects missing or incorrect access controls", category="security")
def detect_access_control(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect privileged functions that lack access control.

    A function is only reported when all of the following hold:
      * it is public/external and not view/pure,
      * its name signals a privileged operation,
      * it actually performs something sensitive (writes contract-global state or
        moves value to an address that is not provably ``msg.sender``),
      * no authorization guard (modifier or inline ``msg.sender``/``tx.origin``
        check) applies to it.
    """
    if node.get("nodeType") != "FunctionDefinition":
        return
    if not _is_public_external(node) or _is_view_pure(node):
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_library or cinfo.is_interface:
        return
    if (cinfo.name or "").lower().startswith("migrations"):
        return

    name = node.get("name", "")
    if node.get("isConstructor") or node.get("kind") == "constructor":
        return
    privileged_name = function_is_sensitive(ctx, cinfo, node)
    ownership_write = _writes_ownership_state(ctx, cinfo, node)
    selfdestruct = _calls_selfdestruct(node.get("body"))
    confused_sign = _confused_sign_withdraw(ctx, cinfo, node)
    payout_no_clear = _payout_without_balance_update(ctx, cinfo, node)
    if not (privileged_name or ownership_write or selfdestruct or confused_sign or payout_no_clear):
        return
    if ctx.function_has_guard(cinfo, node):
        return
    if function_reentrancy_guarded(ctx, cinfo, node):
        return

    if ownership_write and not privileged_name:
        why = "writes an ownership/admin state variable"
    elif selfdestruct and not privileged_name:
        why = "can destroy the contract (selfdestruct/suicide)"
    elif confused_sign:
        why = "uses an inverted balance comparison in a withdrawal"
    elif payout_no_clear:
        why = "pays out a balance without clearing/subtracting it"
    else:
        why = "performs a privileged operation"
    findings.append(AccessControlFinding(
        message=f"Function '{name}' {why} but lacks access control "
                f"(no auth modifier or msg.sender/tx.origin check).",
        severity=Severity.HIGH,
        line_number=_parse_line(node, file_path),
        file_path=file_path,
        source_code=node.get("src")
    ))


@detector("denial_of_service", "🛑 Denial of Service", "Detects denial-of-service vulnerabilities", category="security")
def detect_denial_of_service(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect denial-of-service patterns: unbounded array growth or external calls
    in loops (block-gas-limit DoS) and refund calls that revert the whole
    transaction when a stored recipient rejects (SWC-113/SWC-128)."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    if not _is_public_external(node) or _is_view_pure(node):
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_library or cinfo.is_interface:
        return
    body = node.get("body")

    reason = None
    for n in walk_nodes(body):
        if not node_is(n, "ForStatement"):
            continue
        loop_body = n.get("body")
        for sub in walk_nodes(loop_body):
            if node_is(sub, "FunctionCall"):
                ex = sub.get("expression", {})
                m = ex.get("memberName") if node_is(ex, "MemberAccess") else ex.get("name")
                m = (m or "").lower()
                if m in ("push", "append"):
                    if _target_refs_state(ex.get("expression"), cinfo):
                        reason = "grows a state array inside a loop (unbounded storage growth)"
                        break
                elif low_level_call_member(sub) in ("send", "transfer"):
                    reason = "makes value-transferring payments inside a loop (block-gas-limit DoS)"
                    break
        if reason:
            break

    if reason is None:
        for n in walk_nodes(body):
            if not node_is(n, "FunctionCall"):
                continue
            if ident_name(n.get("expression")) not in ("require", "assert"):
                continue
            args = n.get("arguments", []) or []
            if not args:
                continue
            cond = args[0]
            if node_is(cond, "FunctionCall") and low_level_call_member(cond) in ("send", "transfer", "call"):
                target = call_target(cond)
                if target is not None and _target_refs_state(target, cinfo):
                    reason = "wraps a payment to a stored recipient in require(), so a rejecting " \
                             "recipient can permanently block the function"
                    break

    if reason:
        findings.append(DoSFinding(
            message=f"Function '{node.get('name')}' may be denial-of-serviceable: {reason}.",
            severity=Severity.HIGH,
            line_number=_parse_line(node, file_path),
            file_path=file_path,
            source_code=node.get("src")
        ))


@detector("flash_loan", "⚡ Flash Loan", "Detects potential flash loan vulnerabilities", category="security")
def detect_flash_loan(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect flash-loan entry points that never validate repayment via a callback."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    if not _is_public_external(node) or _is_view_pure(node):
        return
    ctx = get_analysis_context()
    if ctx is not None:
        cinfo = ctx.contract_for_function(node)
        if cinfo is not None and (cinfo.is_interface or cinfo.is_library):
            return
    name = (node.get("name") or "").lower()
    if not name.startswith("flash"):
        return

    body = node.get("body")
    has_callback = False
    for n in walk_nodes(body):
        if node_is(n, "Identifier") and _FLASH_CALLBACK_RE.search(n.get("name", "").lower()):
            has_callback = True
            break
        if node_is(n, "MemberAccess") and _FLASH_CALLBACK_RE.search(n.get("memberName", "").lower()):
            has_callback = True
            break
    if not has_callback:
        findings.append(FlashLoanFinding(
            message=f"Flash loan function '{node.get('name')}' does not appear to "
                    f"enforce repayment through a callback. Verify repayment validation.",
            severity=Severity.HIGH,
            line_number=_parse_line(node, file_path),
            file_path=file_path,
            source_code=node.get("src")
        ))


def _mev_risk(ctx, cinfo, node) -> bool:
    name = (node.get("name") or "").lower()
    if not any(t in name for t in ("swap", "mint", "burn", "claim", "buy",
                                   "sell", "trade", "arbitrage")):
        return False
    if _is_view_pure(node):
        return False
    if not _is_public_external(node):
        return False
    if function_has_mev_protection(node):
        return False
    body = node.get("body")
    if not (_reads_price(body) or _moves_tokens(body)):
        return False
    return True


def _approve_race(node, ctx, cinfo) -> bool:
    """SWC-114: ``approve`` overwrites an existing allowance without a zero-then-set
    first (allows the approved spender to front-run the reset and spend both)."""
    name = (node.get("name") or "").lower()
    if not (_is_public_external(node) or node.get("isConstructor")) or _is_view_pure(node):
        return False
    body = node.get("body")
    allowance_base = None
    for n in walk_nodes(body):
        if not node_is(n, "Assignment"):
            continue
        lhs = n.get("leftHandSide")
        if not node_is(lhs, "IndexAccess"):
            continue
        base = index_base(lhs)
        bname = ident_name(base)
        if not bname or "allow" not in bname.lower():
            continue
        allowance_base = bname
        break
    if allowance_base is None and name != "approve":
        return False
    if allowance_base is None:
        for n in walk_nodes(body):
            if not node_is(n, "Assignment"):
                continue
            if "allow" in (_write_target_name(n, cinfo) or "").lower():
                allowance_base = _write_target_name(n, cinfo)
                break
    if allowance_base is None:
        return False
    if _has_zero_allowance_reset(body):
        return False
    return True


def _is_zero_literal(expr) -> bool:
    if node_is(expr, "Literal"):
        v = str(expr.get("value") or "").strip().lower()
        if v in ("0", "0x0", "0x00"):
            return True
    if node_is(expr, "FunctionCall") and ident_name(expr.get("expression")) in ("address", "int", "uint"):
        for sub in walk_nodes(expr):
            if node_is(sub, "Literal") and str(sub.get("value") or "").strip().lower() in ("0", "0x0", "0x00"):
                return True
    return False


def _mentions_allowance(expr) -> bool:
    for sub in walk_nodes(expr):
        if node_is(sub, "Identifier") and "allow" in (sub.get("name") or "").lower():
            return True
        if node_is(sub, "IndexAccess"):
            base = index_base(sub)
            if base is not None and "allow" in (ident_name(base) or "").lower():
                return True
    return False


def _has_zero_allowance_reset(body) -> bool:
    """True if the function requires/asserts an allowance reset to zero first
    (the SWC-114 mitigation pattern): a comparison of the allowance itself
    against zero, e.g. ``require(_allowed[a][b] == 0)``."""
    for n in walk_nodes(body):
        if not node_is(n, "FunctionCall"):
            continue
        if ident_name(n.get("expression")) not in ("require", "assert"):
            continue
        args = n.get("arguments", []) or []
        if not args:
            continue
        for bo in walk_nodes(args[0]):
            if not node_is(bo, "BinaryOperation"):
                continue
            if bo.get("operator") not in ("==", "!=", "<", ">", "<=", ">="):
                continue
            left = bin_operand(bo, "left")
            right = bin_operand(bo, "right")
            if left is None or right is None:
                continue
            l_zero, r_zero = _is_zero_literal(left), _is_zero_literal(right)
            if not (l_zero or r_zero):
                continue
            other = right if l_zero else left
            if other is not None and _mentions_allowance(other):
                return True
    return False


def _hash_puzzle_payout(node, ctx, cinfo) -> bool:
    """A public function that pays out when user input hashes to a public constant
    (``require(constant == sha3(solution))``); the winning input is observable in
    the mempool and can be front-run."""
    body = node.get("body")
    puzzle = False
    for n in walk_nodes(body):
        if not node_is(n, "FunctionCall"):
            continue
        ex = n.get("expression", {})
        nm = (ex.get("memberName") or ex.get("name") or "").lower()
        if nm not in ("keccak256", "sha3", "sha256", "sha", "ripemd160"):
            continue
        for anc in walk_nodes(body):
            if node_is(anc, "BinaryOperation") and anc.get("operator") in ("==", "!="):
                left = bin_operand(anc, "left")
                right = bin_operand(anc, "right")
                if left is n or right is n:
                    other = right if left is n else left
                    if other is not None and _expr_is_constant_like(other, cinfo):
                        puzzle = True
                        break
        if puzzle:
            break
    if not puzzle:
        return False
    return _moves_tokens(body)


def _expr_is_constant_like(expr, cinfo) -> bool:
    for sub in walk_nodes(expr):
        if node_is(sub, "Literal"):
            return True
        if node_is(sub, "Identifier"):
            name = sub.get("name") or ""
            if name in ("hash", "target", "answer", "solution", "winning_number", "winningnum"):
                return True
    return False


def _body_uses_msg_value(body) -> bool:
    """True if ``msg.value`` appears in ``body``."""
    for n in walk_nodes(body):
        if (
            node_is(n, "MemberAccess")
            and n.get("memberName") == "value"
            and ident_name(n.get("expression")) == "msg"
        ):
            return True
    return False


def _body_increments_id(body, name) -> bool:
    """True if ``name`` is incremented/decremented anywhere in ``body``."""
    for n in walk_nodes(body):
        if node_is(n, "UnaryOperation") and n.get("operator") in ("++", "--"):
            sub = n.get("subExpression", {})
            if node_is(sub, "Identifier") and sub.get("name") == name:
                return True
        if node_is(n, "Assignment") and n.get("operator") in ("+=", "-="):
            lhs = n.get("leftHandSide")
            if node_is(lhs, "Identifier") and lhs.get("name") == name:
                return True
    return False


def _commitment_game(node, ctx, cinfo) -> bool:
    """A payable input-storing function whose contract later pays out based on the
    stored inputs (a reveal-style game) -- the second player can observe the first
    player's move and adapt (front-runnable)."""
    body = node.get("body")
    if not _body_uses_msg_value(body):
        return False
    params = {p.get("name") for p in (node.get("parameters", {}).get("parameters", []) or [])}
    if not params:
        return False
    stores_input = False
    for n in walk_nodes(body):
        if node_is(n, "Assignment"):
            lhs = n.get("leftHandSide")
            if not _target_refs_state(lhs, cinfo):
                continue
            rhs = n.get("rightHandSide")
            rhs_names = {s.get("name") for s in walk_nodes(rhs)
                         if node_is(s, "Identifier")} & params
            if not rhs_names:
                continue
            if node_is(lhs, "IndexAccess"):
                idx = index_value(lhs)
                idx_names = {s.get("name") for s in walk_nodes(idx)
                             if node_is(s, "Identifier")}
                if any(_body_increments_id(body, nm) for nm in idx_names):
                    stores_input = True
            break
    if not stores_input:
        return False
    for other in cinfo.function_nodes:
        if other is node:
            continue
        if _moves_tokens(other.get("body")):
            return True
    return False


@detector("front_running", "🏃 Front Running", "Detects potential front-running vulnerabilities", category="security")
def detect_front_running(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect user-price/order-sensitive functions without slippage or deadline
    protection that may be front-runnable."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_interface:
        return

    if _approve_race(node, ctx, cinfo):
        findings.append(FrontRunningFinding(
            message=f"Function '{node.get('name')}' overwrites an allowance "
                    f"without a zero-then-set first (SWC-114); the old spender can "
                    f"front-run the reset and spend the full amount.",
            severity=Severity.MEDIUM,
            line_number=_parse_line(node, file_path),
            file_path=file_path,
            source_code=node.get("src")
        ))
        return
    if _hash_puzzle_payout(node, ctx, cinfo):
        findings.append(FrontRunningFinding(
            message=f"Function '{node.get('name')}' pays out for a publicly "
                    f"verifiable answer (hash puzzle); the winning input is visible "
                    f"in the mempool and can be front-run.",
            severity=Severity.MEDIUM,
            line_number=_parse_line(node, file_path),
            file_path=file_path,
            source_code=node.get("src")
        ))
        return
    if _commitment_game(node, ctx, cinfo):
        findings.append(FrontRunningFinding(
            message=f"Function '{node.get('name')}' stores user inputs that later "
                    f"determine a payout without a commit-reveal scheme; later "
                    f"players can observe earlier inputs and front-run.",
            severity=Severity.MEDIUM,
            line_number=_parse_line(node, file_path),
            file_path=file_path,
            source_code=node.get("src")
        ))
        return

    if not _mev_risk(ctx, cinfo, node):
        return
    findings.append(FrontRunningFinding(
        message=f"Function '{node.get('name')}' moves funds or uses price data "
                f"without slippage/deadline protection; may be vulnerable to front-running.",
        severity=Severity.MEDIUM,
        line_number=_parse_line(node, file_path),
        file_path=file_path,
        source_code=node.get("src")
    ))


TS_KIND_SEVERITY = {
    "randomness": Severity.HIGH,
    "equality": Severity.MEDIUM,
    "gating": Severity.LOW,
}
_SEV_RANK = {Severity.LOW: 0, Severity.MEDIUM: 1, Severity.HIGH: 2, Severity.CRITICAL: 3}


@detector("timestamp", "⏰ Timestamp", "Detects timestamp dependence vulnerabilities", category="security")
def detect_timestamp(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Flag ``block.timestamp`` when used as randomness, for equality gating, or
    for relational gating. Severity reflects exploitability: randomness is
    HIGH, exact-time equality gating is MEDIUM, relational gating (deadlines,
    reward windows) is LOW."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    sev = None
    for ts_node, kind, chain in timestamp_uses(node.get("body")):
        if kind not in ("randomness", "equality", "gating"):
            continue
        if _ts_use_benign(node, ts_node, kind, chain):
            continue
        cand = TS_KIND_SEVERITY[kind]
        if sev is None or _SEV_RANK[cand] > _SEV_RANK[sev]:
            sev = cand
    if sev is not None:
        findings.append(TimestampFinding(
            message="block.timestamp used for randomness or time-based gating. "
                    "Use block.number or a commit-reveal scheme for randomness; "
                    "avoid exact-time gating.",
            severity=sev,
            line_number=_parse_line(node, file_path),
            file_path=file_path,
            source_code=node.get("src")
        ))


@detector("bad_randomness", "🎲 Bad Randomness", "Detects predictable randomness", category="security")
def detect_bad_randomness(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Flag functions that derive randomness from predictable block data
    (blockhash, block.timestamp, block.number, block.difficulty)."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    for n, kind in bad_randomness_uses(node.get("body")):
        findings.append(BadRandomnessFinding(
            message=f"Predictable randomness from block data ({kind}). Randomness "
                    f"derived from blockhash/timestamp/number/difficulty is "
                    f"manipulable by miners and can be gamed.",
            severity=Severity.MEDIUM,
            line_number=_parse_line(n, file_path),
            file_path=file_path,
            source_code=n.get("src")
        ))
        return


@detector("delegate_call", "📞 Delegate Call", "Detects delegate call vulnerabilities", category="security")
def detect_delegate_call(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Flag unprotected delegatecall to a non-constant, non-self target."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    name = node.get("name", "")
    if name in ("fallback", "receive", "initialize"):
        return
    if node.get("isConstructor"):
        return
    if node.get("visibility") in ("internal", "private"):
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_library or cinfo.is_interface:
        return
    if ctx.function_has_guard(cinfo, node):
        return

    body = node.get("body")
    for n in walk_nodes(body):
        if low_level_call_member(n) != "delegatecall":
            continue
        target = call_target(n)
        if target is None:
            continue
        if _expr_contains_this(target):
            continue
        # Skip fixed-literal targets (e.g., deploy-only addresses).
        if node_is(target, "Literal"):
            continue
        findings.append(DelegateCallFinding(
            message=f"Unprotected delegatecall in function '{name}' to a variable "
                    f"target. Ensure the target is immutable/authorized and storage "
                    f"layouts are compatible.",
            severity=Severity.HIGH,
            line_number=_parse_line(node, file_path),
            file_path=file_path,
            source_code=node.get("src")
        ))
        return


@detector("uninitialized", "❓ Uninitialized", "Detects uninitialized variables", category="security")
def detect_uninitialized(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Flag non-constant state variables that are never written anywhere in the contract."""
    if node.get("nodeType") != "ContractDefinition":
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_node(node)
    if cinfo is None or cinfo.is_interface:
        return
    written = collect_written_state_names(cinfo, ctx)
    parts = [cinfo] + (ctx.bases(cinfo) if ctx else []) + (ctx.derived_of(cinfo) if ctx else [])
    referenced: set = set()
    for c in parts:
        for func in c.function_nodes + c.modifier_nodes:
            for n in walk_nodes(func.get("body")):
                if node_is(n, "Identifier"):
                    referenced.add(n.get("name"))
    for sv in cinfo.state_vars:
        if _is_constant_var(sv):
            continue
        if sv.get("value") is not None:
            continue
        if re.fullmatch(r"_+gap\d*", sv.get("name", "")):
            continue
        if sv.get("name") in referenced and sv.get("name") not in written:
            pass
        else:
            continue
        findings.append(UninitializedFinding(
            message=f"State variable '{sv.get('name')}' is declared without an "
                    f"initializer and is never assigned anywhere in the contract.",
            severity=Severity.MEDIUM,
            line_number=_parse_line(sv, file_path),
            file_path=file_path,
            source_code=sv.get("src")
        ))


def _is_address_param(param: Dict[str, Any]) -> bool:
    tn = param.get("typeName", {})
    if tn.get("nodeType") == "ElementaryTypeName":
        return tn.get("name") == "address"
    if tn.get("nodeType") == "UserDefinedTypeName":
        return True
    return False


def _param_stored_in_state(ctx, cinfo, body: Any, param_name: str) -> bool:
    """True if ``param_name`` is written into a state variable of the contract."""
    state_names = cinfo.state_var_names | {
        n for b in ctx.bases(cinfo) for n in b.state_var_names
    }
    for n in walk_nodes(body):
        if not node_is(n, "Assignment"):
            continue
        lhs = n.get("leftHandSide")
        if lhs is None:
            continue
        base = lhs
        while node_is(base, "IndexAccess") or node_is(base, "MemberAccess"):
            base = index_base(base)
        if not node_is(base, "Identifier") or base.get("name") not in state_names:
            continue
        rhs = n.get("rightHandSide")
        if rhs is None:
            continue
        for ident in walk_nodes(rhs):
            if ident_name(ident) == param_name:
                return True
    return False


@detector("zero_address", "📍 Zero Address", "Detects missing zero address checks", category="security")
def detect_zero_address(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Flag functions that store address parameters into contract state without
    validating against the zero address (including checks hidden in modifiers)."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    if _is_view_pure(node):
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_library or cinfo.is_interface:
        return
    if file_path:
        low_path = file_path.replace("\\", "/").lower()
        if any(tok in low_path for tok in ("/openzeppelin/", "/mock", "/mocks/", "/test/", "/tests/", "/lib/")):
            return

    params = node.get("parameters", {}).get("parameters", []) or []
    addr_params = [p for p in params if _is_address_param(p)]
    if not addr_params:
        return
    stored = [p for p in addr_params if _param_stored_in_state(ctx, cinfo, node.get("body"), p.get("name"))]
    if not stored:
        return

    modifier_bodies = [m.get("body") for m in ctx.applied_modifiers(cinfo, node)]
    if function_has_zero_check(node.get("body"), modifier_bodies):
        return

    names = ", ".join(p.get("name") for p in stored)
    findings.append(ZeroAddressFinding(
        message=f"Function '{node.get('name')}' uses address parameter(s) "
                f"[{names}] without a zero-address check.",
        severity=Severity.MEDIUM,
        line_number=_parse_line(node, file_path),
        file_path=file_path,
        source_code=node.get("src")
    ))


@detector("mev", "💰 MEV", "Detects MEV vulnerabilities", category="security")
def detect_mev(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect MEV-susceptible token/price operations without protection."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_interface:
        return
    if not _mev_risk(ctx, cinfo, node):
        return
    findings.append(MEVFinding(
        message=f"Function '{node.get('name')}' is an order- or price-sensitive "
                f"operation without slippage/deadline protection.",
        severity=Severity.MEDIUM,
        line_number=_parse_line(node, file_path),
        file_path=file_path,
        source_code=node.get("src")
    ))


@detector("storage_collision", "💾 Storage Collision", "Detects storage collision issues", category="security")
def detect_storage_collision(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Flag contracts that inherit from multiple contracts declaring state variables
    AND look upgradeable (proxy/initializer/diamond patterns). Storage-layout collision
    is only a real risk when the layout is pinned by an already-deployed proxy or
    by an immutable implementation behind a proxy."""
    if node.get("nodeType") != "ContractDefinition":
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_node(node)
    if cinfo is None or cinfo.is_interface:
        return
    if not _is_upgradeable(ctx, cinfo):
        return
    if ctx.derived_of(cinfo):
        return
    stateful = ctx.stateful_bases(cinfo)
    if len(stateful) < 2:
        return
    names = ", ".join(b.name for b in stateful)
    findings.append(StorageCollisionFinding(
        message=f"Contract '{cinfo.name}' inherits from multiple state-bearing base "
                f"contracts ({names}); verify storage layout ordering.",
        severity=Severity.MEDIUM,
        line_number=_parse_line(node, file_path),
        file_path=file_path,
        source_code=node.get("src")
    ))


_UPGRADE_FUNC_RE = re.compile(
    r"(initializ|_authorizeupgrade|upgradeto|setimplementation|changeimplementation|"
    r"proxiable|implementation|setimpl|changesimpl|upgradeandcall)"
)
_UPGRADE_STATE_RE = re.compile(r"(implementation|__gap|gap\d+|_initialized|proxy|slot)")


def _is_upgradeable(ctx, cinfo) -> bool:
    """Heuristic: does the inheritance closure look upgradeable/proxy-backed?"""
    parts = [cinfo] + ctx.bases(cinfo) + ctx.derived_of(cinfo)
    for c in parts:
        for f in c.function_nodes:
            if _UPGRADE_FUNC_RE.search((f.get("name") or "").lower()):
                return True
        for sv in c.state_vars:
            if _UPGRADE_STATE_RE.search((sv.get("name") or "").lower()):
                return True
    return False


@detector("upgrade", "⬆️ Upgrade", "Detects upgrade pattern issues", category="security")
def detect_upgrade(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Flag public upgrade entry points that lack access control."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    name = (node.get("name") or "").lower()
    if not any(token in name for token in UPGRADE_NAME_TOKENS):
        return
    if not _is_public_external(node) or _is_view_pure(node):
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_library or cinfo.is_interface:
        return
    if ctx.function_has_guard(cinfo, node):
        return
    findings.append(UpgradeFinding(
        message=f"Upgrade function '{node.get('name')}' lacks access control.",
        severity=Severity.HIGH,
        line_number=_parse_line(node, file_path),
        file_path=file_path,
        source_code=node.get("src")
    ))


@detector("cross_chain", "🌉 Cross Chain", "Detects cross-chain vulnerabilities", category="security")
def detect_cross_chain(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Flag cross-chain bridge functions that lack access control."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    name = (node.get("name") or "").lower()
    if not any(t in name for t in ("bridge", "crosschain", "cross_chain", "multichain")):
        return
    if not _is_public_external(node) or _is_view_pure(node):
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_library or cinfo.is_interface:
        return
    if ctx.function_has_guard(cinfo, node):
        return
    findings.append(CrossChainFinding(
        message=f"Cross-chain function '{node.get('name')}' lacks access control.",
        severity=Severity.HIGH,
        line_number=_parse_line(node, file_path),
        file_path=file_path,
        source_code=node.get("src")
    ))  
