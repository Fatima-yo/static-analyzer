"""
Other vulnerability detectors.

This module provides detectors for various other vulnerabilities
using the super-pythonic approach.
"""

import re
from typing import Dict, Any, List

from ..utils import detector, parse_src, UncheckedContext
from ..findings import TxOriginFinding, IntegerOverflowFinding, Severity
from ..context import (
    get_analysis_context, walk_nodes, node_is, ident_name, bin_operand,
)

_MATH_LIKE_WORDS = {"math", "safemath", "fixedpoint", "wad", "ray", "maths"}


def _math_like(name: str) -> bool:
    """True when a contract name clearly denotes a math/arithmetic helper
    (SafeMath, WadRayMath, CarefulMath, ...). CamelCase-aware tokenized match
    avoids false positives such as ``IntegerOverflowAdd`` (contains "wad") or
    ``Array`` (contains "ray")."""
    camel = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", name)
    tokens = re.split(r"[^a-z0-9]+", camel.lower())
    return any(tok in _MATH_LIKE_WORDS for tok in tokens)


def _parse_line(node: Dict[str, Any], file_path: str) -> Any:
    return parse_src(node.get("src"), file_path)


def _tx_origin_uses(body: Any) -> List[Dict[str, Any]]:
    """Return (member_node, is_auth) for each tx.origin usage, marking only those
    used as an authorization identity (comparison or require/assert condition)."""
    results: List[Dict[str, Any]] = []

    def scan(node: Any, parent: Any) -> None:
        if not isinstance(node, dict):
            return
        if (
            node_is(node, "MemberAccess")
            and node.get("memberName") == "origin"
            and ident_name(node.get("expression")) == "tx"
        ):
            auth = False
            if parent is not None:
                pnt = parent.get("nodeType")
                if pnt == "BinaryOperation" and parent.get("operator") in ("==", "!=", ">", "<", ">=", "<="):
                    auth = True
                elif pnt == "FunctionCall" and ident_name(parent.get("expression")) in ("require", "assert"):
                    auth = True
            results.append({"node": node, "auth": auth})
        for key, value in node.items():
            if value is node:
                continue
            if isinstance(value, dict):
                scan(value, node)
            elif isinstance(value, list):
                for item in value:
                    if isinstance(item, dict):
                        scan(item, node)

    scan(body, None)
    return results


@detector("tx_origin", "👤 tx.origin", "Detects tx.origin usage for authorization", category="security")
def detect_tx_origin(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect tx.origin used as an authorization identity."""
    if node.get("nodeType") != "FunctionDefinition":
        return
    for use in _tx_origin_uses(node.get("body")):
        if not use["auth"]:
            continue
        findings.append(TxOriginFinding(
            message="Avoid using `tx.origin` for authorization.",
            severity=Severity.MEDIUM,
            line_number=_parse_line(use["node"], file_path),
            file_path=file_path,
            source_code=use["node"].get("src")
        ))


HASH_CALL_NAMES = {"keccak256", "sha3", "sha256", "ripemd160", "sha"}


def _contains_hash_call(node: Any) -> bool:
    """True if an expression performs a hash call (e.g. the EIP-1967 slot idiom
    ``keccak256("eip1967.proxy.implementation") - 1``, which cannot overflow)."""
    for sub in walk_nodes(node):
        if node_is(sub, "FunctionCall"):
            if ident_name(sub.get("expression")) in HASH_CALL_NAMES:
                return True
    return False


def _op_guard_checked(op_node: Any, guarded: set) -> bool:
    """True if a BinaryOperation's direct operands are individually covered by a
    require/assert guard (SafeMath-style ``require(b <= a)`` before ``a - b``)."""
    if not node_is(op_node, "BinaryOperation"):
        return False
    left = bin_operand(op_node, "left")
    right = bin_operand(op_node, "right")
    for side in (left, right):
        if side is None:
            continue
        key = _expr_key(side)
        if key and key in guarded:
            return True
    return False


def _expr_key(node: Any) -> str:
    """Canonical structural key for an expression, e.g. ``balanceOf[msg]`` or
    ``a.foo[x]``. Returns ``""`` for expressions with no stable key."""
    if not isinstance(node, dict):
        return ""
    nt = node.get("nodeType")
    if nt == "Identifier":
        return node.get("name") or ""
    if nt == "IndexAccess":
        base = _expr_key(node.get("base"))
        idx = _expr_key(node.get("index"))
        if base and idx:
            return f"{base}[{idx}]"
        return ""
    if nt == "MemberAccess":
        base = _expr_key(node.get("expression"))
        if base:
            return f"{base}.{node.get('memberName')}"
        return ""
    if nt == "TupleExpression":
        comps = [_expr_key(c) for c in node.get("components", []) or []]
        if comps and all(comps):
            return f"({','.join(comps)})"
        return ""
    if nt == "FunctionCall":
        return _expr_key(node.get("expression"))
    if nt == "BinaryOperation":
        left = _expr_key(node.get("leftExpression"))
        right = _expr_key(node.get("rightExpression"))
        if left and right:
            return f"{left}{node.get('operator')}{right}"
        return ""
    return ""


def _has_arith(node: Any) -> bool:
    for sub in walk_nodes(node):
        if node_is(sub, "BinaryOperation") and sub.get("operator") in ("+", "-", "*"):
            return True
    return False


def _branch_early_exits(stmt: Any) -> bool:
    """True if ``stmt`` (an if-body) unconditionally exits via return/revert/
    throw/break/continue or an error-return helper call (``fail(...)``)."""
    if node_is(stmt, "Return") or node_is(stmt, "ThrowStatement") \
            or node_is(stmt, "RevertStatement") or node_is(stmt, "Break") \
            or node_is(stmt, "Continue"):
        return True
    if node_is(stmt, "Block"):
        return bool(stmt.get("statements")) and all(_branch_early_exits(s) for s in stmt.get("statements"))
    if node_is(stmt, "ExpressionStatement"):
        ex = stmt.get("expression")
        if node_is(ex, "FunctionCall") and ident_name(ex.get("expression")) in ("revert", "fail", "throw"):
            return True
    return False


def _guard_checked_keys(body: Any) -> set:
    """Structural keys of expressions guarded by require/assert. A guard whose
    condition itself performs arithmetic (e.g. ``require(a - b >= 0)``) is the
    vulnerable pattern, not a real check, so it is ignored. Only relational
    comparisons (``<``/``<=``/``>``/``>=``) bound an operand's magnitude; an
    equality check such as ``if (amount == 0) return`` does not protect a later
    ``amount - x`` and is therefore not collected."""
    guarded = set()
    for n in walk_nodes(body):
        cond = None
        if node_is(n, "FunctionCall") and ident_name(n.get("expression")) in ("require", "assert"):
            args = n.get("arguments", []) or []
            if args:
                cond = args[0]
        elif node_is(n, "IfStatement"):
            if _branch_early_exits(n.get("trueBody")) or _branch_early_exits(n.get("falseBody")):
                cond = n.get("condition")
        if cond is None:
            continue
        if not (node_is(cond, "BinaryOperation") and cond.get("operator") in ("<", "<=", ">", ">=")):
            continue
        if _has_arith(cond):
            continue
        for sub in walk_nodes(cond):
            key = _expr_key(sub)
            if key:
                guarded.add(key)
    return guarded


def _find_overflow_ops(body: Any) -> List[Dict[str, Any]]:
    """Arithmetic operations (+,-,*,+=,-=,*=) with an ``in_unchecked`` flag.

    Arithmetic used purely as an array index (``fullMessage[i+2]``) is skipped:
    the index is bounded by the array/collection length, so such ops are not
    reportable overflow vectors.
    """
    ops: List[Dict[str, Any]] = []

    def scan(node: Any, in_unchecked: bool, skip_top: bool = False) -> None:
        if not isinstance(node, dict):
            return
        if node.get("nodeType") == "UncheckedBlock":
            in_unchecked = True
        nt = node.get("nodeType")
        if nt == "IndexAccess":
            scan(node.get("base"), in_unchecked, skip_top=False)
            scan(node.get("index"), in_unchecked, skip_top=True)
            return
        if not skip_top:
            if nt == "Assignment" and node.get("operator") in ("+=", "-=", "*="):
                ops.append({"node": node, "unchecked": in_unchecked})
            elif nt == "BinaryOperation" and node.get("operator") in ("+", "-", "*"):
                ops.append({"node": node, "unchecked": in_unchecked})
        for key, value in node.items():
            if value is node:
                continue
            if isinstance(value, dict):
                scan(value, in_unchecked, skip_top=False)
            elif isinstance(value, list):
                for item in value:
                    if isinstance(item, dict):
                        scan(item, in_unchecked, skip_top=False)

    scan(body, False)
    return ops


@detector("integer_overflow", "🔢 Integer Overflow", "Detects potential integer overflow", category="security")
def detect_integer_overflow(node: Dict[str, Any], findings: List, file_path: str = None,
                            version: tuple = None, unchecked_context: UncheckedContext = None) -> None:
    """Detect integer overflow/underflow.

    Only flags pre-0.8 arithmetic (or 0.8+ inside ``unchecked`` blocks), skips
    math libraries, and skips operations guarded by an explicit require/assert on
    the same variables (SafeMath-style checked math).
    """
    if node.get("nodeType") != "FunctionDefinition":
        return
    if version is None:
        return

    major, minor, _ = version
    is_old = (major, minor) < (0, 8)

    ctx = get_analysis_context()
    cinfo = ctx.contract_for_function(node) if ctx else None
    if cinfo is None:
        return
    if cinfo.is_library or _math_like(cinfo.name):
        return

    body = node.get("body")
    guarded = _guard_checked_keys(body)

    for op in _find_overflow_ops(body):
        if not is_old and not op["unchecked"]:
            continue
        op_node = op["node"]
        if op_node.get("nodeType") == "Assignment":
            key = _expr_key(op_node.get("leftHandSide"))
            if key and key in guarded:
                continue
        else:
            key = _expr_key(op_node)
            if key and key in guarded:
                continue
            if _op_guard_checked(op_node, guarded):
                continue
            if _contains_hash_call(op_node):
                continue
        findings.append(IntegerOverflowFinding(
            message=f"Potential integer overflow/underflow with operator "
                    f"'{op_node.get('operator')}'.",
            severity=Severity.MEDIUM,
            line_number=_parse_line(op_node, file_path),
            file_path=file_path,
            source_code=op_node.get("src")
        ))
