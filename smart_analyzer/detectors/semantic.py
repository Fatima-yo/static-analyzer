"""
Semantic Phase-2 vulnerability detectors.

This module implements four context-aware detectors that reason about value
flows and arithmetic at the function/contract level using ``AnalyzerContext``:

- ``value_flow`` (2a): balance-accounting mismatches where a malicious or
  fee-on-transfer/rebasing token lets a counterparty over-credit an internal
  balance and redirect funds.
- ``callback_reentrancy`` (2b): reentrancy surfaces via token transfer callback
  hooks (ERC777 / ERC721 / ERC1155 / ERC223), which the generic reentrancy
  detector does not model.
- ``integer_truncation`` (2c): divide-before-multiply precision loss in
  value-critical arithmetic.
- ``oracle_taint`` (2d): oracle reads (Chainlink or AMM/TWAP) flowing into value
  movement without staleness / manipulation validation.
"""

import json as _json
import re
from typing import Dict, Any, List

from ..utils import detector, parse_src
from ..findings import (
    ValueFlowFinding, CallbackReentrancyFinding, IntegerTruncationFinding,
    OracleTaintFinding, Severity,
)
from ..context import (
    get_analysis_context, walk_nodes, node_is, ident_name, index_base,
    index_value, bin_operand, low_level_call_member, call_target,
    _expr_mentions_msg_sender, _expr_contains_this,
    _write_target_name, _write_is_per_user, _moves_tokens,
    _function_has_value_call, _high_level_state_call,
    CHAINLINK_READS, _has_staleness_check,
)

# --------------------------------------------------------------------------
# Shared small helpers.
# --------------------------------------------------------------------------


def _parse_line(node: Dict[str, Any], file_path: str) -> Any:
    return parse_src(node.get("src"), file_path)


def _is_view_pure(node: Dict[str, Any]) -> bool:
    return node.get("stateMutability") in ("view", "pure")


def _call_member(node: Dict[str, Any]) -> str:
    ex = node.get("expression", {})
    return ex.get("memberName") or ex.get("name") or ""


def _params(func: Dict[str, Any]) -> set:
    return {p.get("name") for p in (func.get("parameters", {}).get("parameters", []) or [])
            if p.get("name")}


def _expr_refs_param(expr: Any, params: set) -> bool:
    if not params:
        return False
    for n in walk_nodes(expr):
        if node_is(n, "Identifier") and n.get("name") in params:
            return True
    return False


def _expr_attacker_controlled(expr: Any, params: set, cinfo) -> bool:
    """True when ``expr`` derives from ``msg.sender`` or a function parameter."""
    return _expr_mentions_msg_sender(expr) or _expr_refs_param(expr, params)


def _math_like(name: str) -> bool:
    camel = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", name)
    tokens = re.split(r"[^a-z0-9]+", camel.lower())
    return any(tok in {"math", "safemath", "fixedpoint", "wad", "ray", "maths"}
               for tok in tokens)


def _src_offset(node: Any) -> int:
    try:
        return int(str(node.get("src", "")).split(":")[0])
    except (ValueError, IndexError, TypeError):
        return -1


def _assignment_amount_expr(node: Dict[str, Any]) -> Any:
    if node.get("nodeType") == "Assignment":
        return node.get("rightHandSide") or node.get("rightExpression")
    return None


# --------------------------------------------------------------------------
# Balance-accounting helpers.
# --------------------------------------------------------------------------

_BALANCE_TOKENS = ("balance", "supply", "share", "credit", "debt", "reward",
                   "staked", "collateral", "pooled", "deposit")


def _write_is_balance_like(node: Dict[str, Any], cinfo) -> bool:
    name = _write_target_name(node, cinfo) or ""
    low = name.lower()
    return any(tok in low for tok in _BALANCE_TOKENS)


def _write_is_user_account(node: Dict[str, Any], cinfo, params: set) -> bool:
    target = node.get("leftHandSide") or node.get("subExpression") or node.get("expression")
    if node_is(target, "IndexAccess"):
        idx = index_value(target)
        if idx is None:
            return False
        if _expr_mentions_msg_sender(idx):
            return True
        if _expr_refs_param(idx, params):
            return True
    return False


def _writes_balance_state(body: Any, cinfo) -> bool:
    for n in walk_nodes(body):
        if n.get("nodeType") not in ("Assignment", "UnaryOperation", "DeleteStatement"):
            continue
        if _write_is_balance_like(n, cinfo) or _write_is_per_user(n):
            return True
    return False


def _reads_self_balance_of(body: Any, token: Any) -> bool:
    """True when the body reads ``<token>.balanceOf(address(this))``-style
    actual holdings, i.e. the author verifies real balance deltas."""
    token_name = ident_name(token)
    for n in walk_nodes(body):
        if not node_is(n, "FunctionCall"):
            continue
        if _call_member(n).lower() != "balanceof":
            continue
        base = n.get("expression", {}).get("expression")
        if token_name is not None and ident_name(base) == token_name:
            for a in n.get("arguments") or []:
                if _expr_contains_this(a):
                    return True
    return False


# --------------------------------------------------------------------------
# 2a. Value flow / balance-delta misaccounting.
# --------------------------------------------------------------------------

_INCOMING_TRANSFER_NAMES = ("transferfrom", "safetransferfrom")
_TOKEN_TRANSFER_FUNCS = ("transfer", "transferfrom", "safetransfer",
                         "safetransferfrom", "_transfer")


def _collect_incoming_transfers(body: Any) -> List[Dict[str, Any]]:
    out = []
    for n in walk_nodes(body):
        if not node_is(n, "FunctionCall"):
            continue
        if _call_member(n).lower() not in _INCOMING_TRANSFER_NAMES:
            continue
        args = n.get("arguments") or []
        if len(args) >= 3:
            out.append(n)
    return out


def _find_credit_write(body: Any, cinfo, amount_id: str, params: set) -> Any:
    """Write that credits ``amount_id`` to a per-user balance or supply var."""
    for n in walk_nodes(body):
        if n.get("nodeType") != "Assignment":
            continue
        if not (_write_is_user_account(n, cinfo, params) or _write_is_balance_like(n, cinfo)):
            continue
        amt = _assignment_amount_expr(n)
        if amt is None:
            continue
        for sub in walk_nodes(amt):
            if node_is(sub, "Identifier") and sub.get("name") == amount_id:
                return n
    return None


@detector("value_flow", "💰 Value Flow", "Detects balance-accounting mismatches where a malicious counterparty can redirect funds", severity="MEDIUM", category="security")
def detect_value_flow(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect incoming ``transferFrom`` amounts blindly credited to an internal
    balance, without verifying the actually-received balance.  A fee-on-transfer
    or rebasing token -- or a token address chosen by the caller -- makes the
    recorded credit diverge from real holdings, so a counterparty can
    over-credit and drain other assets."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_interface:
        return
    if _is_view_pure(node):
        return
    if (node.get("name") or "").lower() in _TOKEN_TRANSFER_FUNCS:
        return

    body = node.get("body")
    params = _params(node)
    transfers = _collect_incoming_transfers(body)
    if not transfers:
        return

    for call in transfers:
        args = call.get("arguments") or []
        amount_id = ident_name(args[2])
        if amount_id is None:
            continue
        token = call.get("expression", {}).get("expression")
        if not isinstance(token, dict):
            continue
        if _expr_contains_this(token):
            continue
        if _reads_self_balance_of(body, token):
            continue
        credit = _find_credit_write(body, cinfo, amount_id, params)
        if credit is None:
            continue
        attacker_token = _expr_attacker_controlled(token, params, cinfo)
        target_name = _write_target_name(credit, cinfo) or ""
        if attacker_token and any(tok in target_name.lower()
                                  for tok in ("share", "supply", "total")):
            severity = Severity.HIGH
        else:
            severity = Severity.MEDIUM
        findings.append(ValueFlowFinding(
            message=(
                "The amount requested in the token transfer ('{amount}') is "
                "credited to '{target}' without verifying the balance actually "
                "received. A fee-on-transfer or rebasing token{who} makes the "
                "recorded credit diverge from real holdings, letting a "
                "counterparty over-credit and redirect funds; read "
                "balanceOf(address(this)) deltas instead.".format(
                    amount=amount_id,
                    target=target_name or "a user balance",
                    who=" (or an address chosen by the caller)" if attacker_token else "",
                )
            ),
            severity=severity,
            line_number=_parse_line(credit, file_path),
            file_path=file_path,
            source_code=credit.get("src"),
        ))
        return


# --------------------------------------------------------------------------
# 2b. Token-transfer callback reentrancy.
# --------------------------------------------------------------------------

_CALLBACK_HANDLER_RE = re.compile(
    r"^(tokensreceived|tokenstosend|onerc721received|onerc1155received|"
    r"onerc1155batchreceived|tokenfallback|ontokentransfer|tokencallback|"
    r"onerc20received|onerc20transfer|onapprovalreceived|onapproval)$",
    re.IGNORECASE,
)


def _handler_has_untrusted_call(ctx, cinfo, body: Any) -> bool:
    for n in walk_nodes(body):
        if not node_is(n, "FunctionCall"):
            continue
        member = low_level_call_member(n)
        if member in ("call", "delegatecall", "send"):
            target = call_target(n)
            if target is None or not _expr_contains_this(target):
                return True
        elif _high_level_state_call(n, cinfo):
            return True
    return False


def _state_write_after(body: Any, call_node: Dict[str, Any], cinfo, params: set) -> bool:
    call_off = _src_offset(call_node)
    if call_off < 0:
        return False
    for n in walk_nodes(body):
        if n.get("nodeType") not in ("Assignment", "UnaryOperation", "DeleteStatement"):
            continue
        if not (_write_is_user_account(n, cinfo, params) or _write_is_balance_like(n, cinfo)):
            continue
        woff = _src_offset(n)
        if woff >= 0 and woff > call_off:
            return True
    return False


@detector("callback_reentrancy", "🔁 Callback Reentrancy", "Detects reentrancy via token transfer callbacks (ERC777/ERC721/ERC1155/ERC223)", severity="HIGH", category="security")
def detect_callback_reentrancy(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect two callback-reentrancy surfaces the generic reentrancy detector
    does not model: (1) token callback-handler functions (``tokensReceived``,
    ``onERC721Received``, ...) that perform untrusted external calls, and (2)
    hook-capable transfers (``safeTransferFrom``/``safeTransfer``) of a
    user-controlled token followed by a state write."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_interface:
        return

    name = node.get("name") or ""
    body = node.get("body")

    if _CALLBACK_HANDLER_RE.match(name):
        if _handler_has_untrusted_call(ctx, cinfo, body):
            findings.append(CallbackReentrancyFinding(
                message=(
                    "Token callback handler '{name}' is invoked by any token "
                    "transfer to this contract (ERC777/ERC721/ERC1155/ERC223 "
                    "hook) and performs untrusted external calls; a malicious "
                    "token can re-enter this contract mid-transfer and observe "
                    "inconsistent state.".format(name=name)
                ),
                severity=Severity.HIGH,
                line_number=_parse_line(node, file_path),
                file_path=file_path,
                source_code=node.get("src"),
            ))
        return

    if _is_view_pure(node):
        return
    params = _params(node)
    for n in walk_nodes(body):
        if not node_is(n, "FunctionCall"):
            continue
        member = _call_member(n).lower()
        if member not in ("safetransferfrom", "safetransfer"):
            continue
        token = n.get("expression", {}).get("expression")
        if not isinstance(token, dict):
            continue
        if not _expr_attacker_controlled(token, params, cinfo):
            continue
        args = n.get("arguments") or []
        recipient = None
        if member == "safetransferfrom" and len(args) >= 2:
            recipient = args[1]
        elif member == "safetransfer" and len(args) >= 1:
            recipient = args[0]
        if recipient is None or _expr_contains_this(recipient):
            continue
        if not _state_write_after(body, n, cinfo, params):
            continue
        findings.append(CallbackReentrancyFinding(
            message=(
                "Hook-capable transfer ('{member}') of a user-controlled token "
                "is followed by a state write; the recipient's token callback "
                "(ERC777/ERC721/ERC1155) can re-enter and observe inconsistent "
                "state. Update state before the transfer or add a reentrancy "
                "guard.".format(member=member)
            ),
            severity=Severity.MEDIUM,
            line_number=_parse_line(n, file_path),
            file_path=file_path,
            source_code=n.get("src"),
        ))
        return


# --------------------------------------------------------------------------
# 2c. Integer truncation / rounding-down.
# --------------------------------------------------------------------------

def _unwrap(expr: Any) -> Any:
    """Strip parenthesized grouping: solc encodes ``(a / b)`` as a
    single-component ``TupleExpression`` that wraps the real sub-expression."""
    for _ in range(8):
        if not isinstance(expr, dict):
            break
        if expr.get("nodeType") == "TupleExpression":
            comps = expr.get("components") or []
            if len(comps) == 1:
                expr = comps[0]
                continue
        break
    return expr


def _expr_key(e: Any) -> tuple:
    e = _unwrap(e)
    if node_is(e, "Identifier"):
        return ("id", e.get("name"))
    if node_is(e, "Literal"):
        return ("lit", e.get("kind"), e.get("value"))
    if node_is(e, "MemberAccess"):
        return ("mem", _expr_key(index_base(e)), e.get("memberName"))
    if node_is(e, "IndexAccess"):
        return ("idx", _expr_key(index_base(e)), _expr_key(index_value(e)))
    if node_is(e, "BinaryOperation"):
        return ("bin", e.get("operator"),
                _expr_key(bin_operand(e, "left")),
                _expr_key(bin_operand(e, "right")))
    return ("expr", _json.dumps(e, sort_keys=True))


def _division_lossy(div: Any, other: Any) -> bool:
    """True when ``div`` is a '/' that truncates before being multiplied by
    ``other`` (the ``(a / b) * c`` shape), excluding the intentional
    rounding-to-a-multiple idiom ``(a / d) * d``."""
    div = _unwrap(div)
    other = _unwrap(other)
    if not node_is(div, "BinaryOperation"):
        return False
    if div.get("operator") != "/":
        return False
    divisor = bin_operand(div, "right")
    if divisor is None or other is None:
        return False
    return _expr_key(divisor) != _expr_key(other)


@detector("integer_truncation", "✂️ Integer Truncation", "Detects divide-before-multiply precision loss in value-critical arithmetic", severity="MEDIUM", category="security")
def detect_integer_truncation(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect ``(a / b) * c`` (divide before multiply) inside functions that
    move value or update balances: the division rounds down first, so per-user
    math can under- or over-credit amounts that an attacker can exploit with
    dust-sized inputs."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_interface or cinfo.is_library:
        return
    if _math_like(cinfo.name):
        return
    if _is_view_pure(node):
        return

    body = node.get("body")
    if not (_moves_tokens(body) or _function_has_value_call(node)
            or _writes_balance_state(body, cinfo)):
        return

    for n in walk_nodes(body):
        if not node_is(n, "BinaryOperation") or n.get("operator") != "*":
            continue
        left = bin_operand(n, "left")
        right = bin_operand(n, "right")
        if _division_lossy(left, right) or _division_lossy(right, left):
            findings.append(IntegerTruncationFinding(
                message=(
                    "Integer truncation: a division rounds down before a "
                    "multiplication (divide-before-multiply). Precision loss in "
                    "value-critical math can under-credit/over-credit per-user "
                    "amounts; multiply first, then divide."
                ),
                severity=Severity.MEDIUM,
                line_number=_parse_line(n, file_path),
                file_path=file_path,
                source_code=n.get("src"),
            ))
            return


# --------------------------------------------------------------------------
# 2d. Oracle reads tainting value movement.
# --------------------------------------------------------------------------

_CHAINLINK_READS_LC = tuple(c.lower() for c in CHAINLINK_READS)
_AMM_ORACLE_READS = ("getreserves", "slot0", "observe", "price0cumulativelast",
                     "price1cumulativelast", "getamountsout", "getamountin",
                     "latestanswer", "getquote", "getquotedebt")


def _oracle_reads(body: Any) -> List[Dict[str, Any]]:
    out = []
    for n in walk_nodes(body):
        if not node_is(n, "FunctionCall"):
            continue
        name = _call_member(n).lower()
        if name in _CHAINLINK_READS_LC or name in _AMM_ORACLE_READS:
            out.append(n)
    return out


@detector("oracle_taint", "🎯 Oracle Taint", "Detects oracle reads flowing into value movement without manipulation/staleness validation", severity="HIGH", category="security")
def detect_oracle_taint(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect functions where an oracle/price read (Chainlink feed, AMM reserves
    or TWAP accumulator) coexists with value movement or balance updates and no
    staleness / manipulation validation, so an attacker who can skew the price
    source taints the payout amount."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_interface:
        return

    body = node.get("body")
    reads = _oracle_reads(body)
    if not reads:
        return
    if _has_staleness_check(body):
        return
    if not (_moves_tokens(body) or _function_has_value_call(node)
            or _writes_balance_state(body, cinfo)):
        return

    for read in reads:
        name = _call_member(read).lower()
        is_chainlink = name in _CHAINLINK_READS_LC or name in ("latestanswer",)
        findings.append(OracleTaintFinding(
            message=(
                "Oracle read ('{name}') feeds a function that moves value or "
                "updates balances, without staleness/manipulation validation. "
                "An attacker controlling the price source (stale feed, "
                "flashable liquidity, short TWAP window) can taint the payout "
                "amount.".format(name=name)
            ),
            severity=Severity.HIGH if is_chainlink else Severity.MEDIUM,
            line_number=_parse_line(read, file_path),
            file_path=file_path,
            source_code=read.get("src"),
        ))
