"""
Project-level analysis context for the Solidity Static Analyzer.

Detectors previously operated on a flat stream of AST nodes with no knowledge of
which contract a function belongs to, which modifiers apply (including inherited
ones), or whether state is ever written elsewhere.  This module builds an index
over the full compilation (all sources) and exposes the semantic helpers that
detectors need to avoid the degenerate pattern-matching that produced thousands
of false positives.
"""

import re
from typing import Any, Dict, Iterator, List, Optional, Tuple
from contextvars import ContextVar

# --------------------------------------------------------------------------
# Current-context plumbing (avoids changing every detector signature).
# --------------------------------------------------------------------------

_CTX: ContextVar = ContextVar("smart_analyzer_ctx", default=None)


def set_analysis_context(ctx: Optional['AnalyzerContext']) -> None:
    _CTX.set(ctx)


def get_analysis_context() -> Optional['AnalyzerContext']:
    return _CTX.get()


# --------------------------------------------------------------------------
# Generic AST walking helpers.
# --------------------------------------------------------------------------

def walk_nodes(node: Any) -> Iterator[Dict[str, Any]]:
    """Yield every dict node that carries a ``nodeType`` in pre-order."""
    if isinstance(node, dict):
        if node.get("nodeType"):
            yield node
        for v in node.values():
            yield from walk_nodes(v)
    elif isinstance(node, list):
        for item in node:
            yield from walk_nodes(item)


def node_is(node: Any, node_type: str) -> bool:
    return isinstance(node, dict) and node.get("nodeType") == node_type


def index_base(node: Any) -> Optional[Dict[str, Any]]:
    """Underlying expression of an IndexAccess/MemberAccess node, handling both
    the ``base`` (solc >=0.6) and ``baseExpression`` (solc 0.4/0.5) fields."""
    if isinstance(node, dict) and node.get("nodeType") in ("IndexAccess", "MemberAccess"):
        base = node.get("base") or node.get("baseExpression") or node.get("expression")
        return base if isinstance(base, dict) else None
    return None


def index_value(node: Any) -> Optional[Dict[str, Any]]:
    """Index expression of an IndexAccess node (``index`` / ``indexExpression``)."""
    if isinstance(node, dict) and node.get("nodeType") == "IndexAccess":
        index = node.get("index") or node.get("indexExpression")
        return index if isinstance(index, dict) else None
    return None


def bin_operand(node: Any, side: str) -> Optional[Dict[str, Any]]:
    """Operand of a BinaryOperation handling both ``leftExpression``/``rightExpression``
    (solc >=0.5) and ``left``/``right`` (solc 0.4) field names."""
    if isinstance(node, dict) and node.get("nodeType") == "BinaryOperation":
        operand = node.get(side + "Expression") or node.get(side)
        return operand if isinstance(operand, dict) else None
    return None


def ident_name(node: Any) -> Optional[str]:
    if node_is(node, "Identifier"):
        return node.get("name")
    return None


# --------------------------------------------------------------------------
# Low-level call helpers.
# --------------------------------------------------------------------------

LOW_LEVEL_CALLS = ("call", "delegatecall", "staticcall", "send")


def _low_level_call_expression(node: Any) -> Optional[Dict[str, Any]]:
    """Return the MemberAccess for a ``.call``-family expression, across the
    solc 0.4.x and 0.5+ AST shapes.

    - 0.5+: ``addr.call.value(x)(...)`` is FunctionCall(FunctionCallOptions(
        MemberAccess(call, addr), options=[value=x])).
    - 0.4.x: ``addr.call.value(x)()`` is FunctionCall(FunctionCall(MemberAccess(
        value, MemberAccess(call, addr)), args=[x])).
    """
    if not node_is(node, "FunctionCall"):
        return None
    ex = node.get("expression", {})
    for _ in range(6):
        if node_is(ex, "FunctionCallOptions") or node_is(ex, "FunctionCall"):
            ex = ex.get("expression", {})
        elif node_is(ex, "MemberAccess"):
            m = ex.get("memberName")
            if m in LOW_LEVEL_CALLS:
                return ex
            if m in ("value", "gas"):
                ex = ex.get("expression", {})
            else:
                return None
        else:
            return None
    return None


def low_level_call_member(node: Any) -> Optional[str]:
    """Return the member name if ``node`` is a low-level ``.call`` family call."""
    ma = _low_level_call_expression(node)
    return ma.get("memberName") if ma is not None else None


def call_target(node: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Return the base expression of a low-level call (the recipient)."""
    ma = _low_level_call_expression(node)
    if ma is None:
        return None
    return ma.get("expression")


def _expr_mentions_msg_sender(expr: Any) -> bool:
    for n in walk_nodes(expr):
        if (
            node_is(n, "MemberAccess")
            and n.get("memberName") == "sender"
            and ident_name(n.get("expression")) == "msg"
        ):
            return True
    return False


def _expr_contains_this(expr: Any) -> bool:
    for n in walk_nodes(expr):
        if ident_name(n) == "this":
            return True
    return False


# --------------------------------------------------------------------------
# Authorization / access-guard detection.
# --------------------------------------------------------------------------

AUTH_HELPER_RE = re.compile(
    r"(only|owner|role|admin|auth|permission|acl|operator|govern|guard|"
    r"allowed|authorized|multisig|timelock|whennot|isowner|isadmin|"
    r"hasaccess|haspermission|checkowner|checkrole)"
)


def _expr_mentions_auth(node: Any) -> bool:
    """True if an expression subtree performs/references an authorization check.

    Recognizes ``msg.sender`` / ``tx.origin`` comparisons and calls to auth-style
    helpers (``onlyOwner``, ``hasRole``, ``_checkOwner``, ...).  A bare variable
    named ``owner`` used as a value does *not* count.
    """
    if not isinstance(node, dict):
        return False
    nt = node.get("nodeType")
    if nt == "MemberAccess":
        if node.get("memberName") == "sender" and ident_name(node.get("expression")) == "msg":
            return True
        if node.get("memberName") == "origin" and ident_name(node.get("expression")) == "tx":
            return True
        return False
    if nt == "FunctionCall":
        ex = node.get("expression", {})
        name = ex.get("name") or ex.get("memberName") or ""
        if AUTH_HELPER_RE.search(name.lower()):
            return True
        for arg in node.get("arguments", []):
            if _expr_mentions_auth(arg):
                return True
        return False
    for key, value in node.items():
        if key in ("src", "id", "typeDescriptions"):
            continue
        if isinstance(value, dict):
            if _expr_mentions_auth(value):
                return True
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, dict) and _expr_mentions_auth(item):
                    return True
    return False


def _branch_terminates(node: Any) -> bool:
    for n in walk_nodes(node):
        if n.get("nodeType") in ("RevertStatement", "Return", "ThrowStatement"):
            return True
        if node_is(n, "FunctionCall"):
            if ident_name(n.get("expression")) in ("revert", "throw", "selfdestruct"):
                return True
    return False


def _mentions_sender(expr: Any) -> bool:
    """True if an expression references ``msg.sender``, ``tx.origin`` or OZ's
    ``_msgSender()`` (an alias for ``msg.sender``) anywhere."""
    for n in walk_nodes(expr):
        if node_is(n, "MemberAccess"):
            if n.get("memberName") == "sender" and ident_name(n.get("expression")) == "msg":
                return True
            if n.get("memberName") == "origin" and ident_name(n.get("expression")) == "tx":
                return True
        if node_is(n, "FunctionCall"):
            name = ident_name(n.get("expression"))
            if name in ("_msgSender", "_msgData"):
                return True
    return False


def _expr_is_auth_identity(node: Any) -> bool:
    """True if an expression uses ``msg.sender``/``tx.origin`` as an authorization
    identity: compared against another identity, or passed to an auth helper.
    Merely *indexing* with msg.sender (``balances[msg.sender]``) does not count."""
    if not isinstance(node, dict):
        return False
    nt = node.get("nodeType")
    if nt == "BinaryOperation" and node.get("operator") in ("==", "!="):
        if _mentions_sender(bin_operand(node, "left")) or _mentions_sender(bin_operand(node, "right")):
            return True
        return False
    if nt == "FunctionCall":
        ex = node.get("expression", {})
        name = (ex.get("name") or ex.get("memberName") or "").lower()
        if AUTH_HELPER_RE.search(name):
            return True
        for arg in node.get("arguments", []):
            if _expr_is_auth_identity(arg):
                return True
        return False
    if nt == "MemberAccess":
        return False
    if nt == "IndexAccess":
        return _expr_is_auth_identity(index_base(node)) or _expr_is_auth_identity(index_value(node))
    for key, value in node.items():
        if key in ("src", "id", "typeDescriptions"):
            continue
        if isinstance(value, dict):
            if _expr_is_auth_identity(value):
                return True
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, dict) and _expr_is_auth_identity(item):
                    return True
    return False


def _statement_is_auth_check(expr: Any) -> bool:
    if node_is(expr, "FunctionCall"):
        if ident_name(expr.get("expression")) in ("require", "assert"):
            args = expr.get("arguments", []) or []
            if args and _expr_is_auth_identity(args[0]):
                return True
    return False


def block_has_auth(node: Any) -> bool:
    """True if a body contains an authorization guard (require/if with msg.sender,
    tx.origin or an auth helper)."""
    if not isinstance(node, dict):
        return False
    nt = node.get("nodeType")
    if nt == "ExpressionStatement":
        return _statement_is_auth_check(node.get("expression"))
    if nt == "IfStatement":
        cond = node.get("condition")
        if _expr_is_auth_identity(cond) and (
            _branch_terminates(node.get("trueBody")) or _branch_terminates(node.get("falseBody"))
        ):
            return True
    for key, value in node.items():
        if key in ("src", "id", "typeDescriptions"):
            continue
        if isinstance(value, dict):
            if block_has_auth(value):
                return True
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, dict) and block_has_auth(item):
                    return True
    return False


MODIFIER_GUARD_RE = re.compile(
    r"(only|owner|role|admin|auth|permission|acl|operator|govern|guard|"
    r"whennot|allowed|authorized|multisig|timelock|initializ)"
)


def modifier_is_guard(mod: Dict[str, Any]) -> bool:
    if MODIFIER_GUARD_RE.search((mod.get("name") or "").lower()):
        return True
    return block_has_auth(mod.get("body"))


REENTRANCY_GUARD_RE = re.compile(r"(nonreentrant|reentrant|onlyonce|oneblock|entered|mutex)")


def modifier_sets_lock(mod: Dict[str, Any]) -> bool:
    for n in walk_nodes(mod.get("body")):
        if n.get("nodeType") in ("Assignment", "UnaryOperation"):
            target = n.get("leftHandSide") or n.get("subExpression")
            name = ""
            while target and target.get("nodeType") in ("IndexAccess", "MemberAccess"):
                target = index_base(target)
            if target:
                name = target.get("name") or ""
            if re.search(r"(status|locked|_entered|guard|lock|entered)", name.lower()):
                return True
    return False


# --------------------------------------------------------------------------
# Zero-address checks.
# --------------------------------------------------------------------------

def _expr_has_zero_address(node: Any) -> bool:
    for n in walk_nodes(node):
        if node_is(n, "FunctionCall"):
            ex = n.get("expression", {})
            if ex.get("nodeType") == "ElementaryTypeNameExpression" and ex.get("typeName", {}).get("name") == "address":
                for arg in n.get("arguments", []):
                    if arg.get("nodeType") == "Literal" and str(arg.get("value", "")).strip().lower() in ("0", "0x0", "0x00"):
                        return True
        if n.get("nodeType") == "Literal":
            v = str(n.get("value", "")).strip().lower()
            if v in ("0", "0x0", "0x00", "0x0000000000000000000000000000000000000000"):
                return True
    return False


def function_has_zero_check(body: Any, modifier_bodies: List[Dict[str, Any]]) -> bool:
    """True if the function body or any applied modifier contains a zero-address check."""
    for src in [body] + modifier_bodies:
        for n in walk_nodes(src):
            if node_is(n, "FunctionCall") and ident_name(n.get("expression")) in ("require", "assert"):
                args = n.get("arguments", []) or []
                if args and _expr_has_zero_address(args[0]):
                    return True
            if n.get("nodeType") == "IfStatement":
                if _expr_has_zero_address(n.get("condition")) and (
                    _branch_terminates(n.get("trueBody")) or _branch_terminates(n.get("falseBody"))
                ):
                    return True
    return False


# --------------------------------------------------------------------------
# State-variable helpers.
# --------------------------------------------------------------------------

def _is_constant_var(sv: Dict[str, Any]) -> bool:
    return bool(sv.get("constant"))


def _is_immutable_var(sv: Dict[str, Any]) -> bool:
    return sv.get("mutability") == "immutable"


def _target_refs_state(node: Any, cinfo: 'ContractInfo', aliases: Optional[set] = None) -> bool:
    if not isinstance(node, dict):
        return False
    nt = node.get("nodeType")
    if nt == "Identifier":
        if aliases and node.get("name") in aliases:
            return True
        return node.get("name") in cinfo.state_var_names
    if nt in ("IndexAccess", "MemberAccess"):
        return _target_refs_state(index_base(node), cinfo, aliases)
    return False


def _collect_storage_aliases(body: Any, cinfo: 'ContractInfo') -> set:
    """Local names that alias a state variable via a `storage` declaration
    (``var acc = Acc[msg.sender]`` / ``Holder storage acc = Acc[msg.sender]``),
    so writes through them count as state writes."""
    aliases: set = set()
    for n in walk_nodes(body):
        if not node_is(n, "VariableDeclarationStatement"):
            continue
        init = n.get("initialValue")
        if init is None:
            continue
        if not _target_refs_state(init, cinfo):
            continue
        for decl in n.get("declarations") or []:
            if (decl.get("storageLocation") or "") in ("storage", "default"):
                if decl.get("name"):
                    aliases.add(decl.get("name"))
    return aliases


def _write_target_name(node: Dict[str, Any], cinfo: 'ContractInfo') -> Optional[str]:
    target = node.get("leftHandSide") or node.get("subExpression") or node.get("expression")
    while target and target.get("nodeType") in ("IndexAccess", "MemberAccess"):
        target = index_base(target)
    if target and node_is(target, "Identifier"):
        return target.get("name")
    return None


def collect_state_events(body: Any, cinfo: 'ContractInfo') -> List[Tuple[str, Dict[str, Any]]]:
    """Pre-order list of ``("write", node)`` / ``("call"|"delegatecall"|..., node)``
    events within a function body."""
    out: List[Tuple[str, Dict[str, Any]]] = []
    aliases = _collect_storage_aliases(body, cinfo)

    def rec(node: Any) -> None:
        if isinstance(node, dict):
            nt = node.get("nodeType")
            if nt == "Assignment":
                if _target_refs_state(node.get("leftHandSide"), cinfo, aliases):
                    out.append(("write", node))
            elif nt == "UnaryOperation":
                if node.get("operator") in ("++", "--") and _target_refs_state(node.get("subExpression"), cinfo, aliases):
                    out.append(("write", node))
            elif nt == "DeleteStatement":
                if _target_refs_state(node.get("expression"), cinfo, aliases):
                    out.append(("write", node))
            elif nt == "FunctionCall":
                member = low_level_call_member(node)
                if member:
                    out.append((member, node))
            for value in node.values():
                if value is node:
                    continue
                if isinstance(value, dict):
                    rec(value)
                elif isinstance(value, list):
                    for item in value:
                        if isinstance(item, dict):
                            rec(item)
        elif isinstance(node, list):
            for item in node:
                if isinstance(item, dict):
                    rec(item)

    rec(body)
    return out


def _collect_state_write_targets(body: Any, state_names: set) -> List[str]:
    """Names of state variables written within ``body`` (any of ``state_names``)."""
    targets: List[str] = []
    aliases: Dict[str, str] = {}

    def refs_state(node: Any) -> bool:
        if not isinstance(node, dict):
            return False
        nt = node.get("nodeType")
        if nt == "Identifier":
            if node.get("name") in aliases:
                return True
            return node.get("name") in state_names
        if nt in ("IndexAccess", "MemberAccess"):
            return refs_state(index_base(node))
        return False

    def state_name(node: Any) -> Optional[str]:
        target = node
        while target and target.get("nodeType") in ("IndexAccess", "MemberAccess"):
            target = index_base(target)
        if target and node_is(target, "Identifier"):
            name = target.get("name")
            if name in aliases:
                return aliases[name]
            if name in state_names:
                return name
        return None

    # Pre-pass: track `Type storage x = <state-var expr>;` aliases.
    for n in walk_nodes(body):
        if node_is(n, "VariableDeclarationStatement"):
            init = n.get("initialValue")
            if init is None:
                continue
            sname = state_name(init)
            if sname is None:
                continue
            for decl in n.get("declarations") or []:
                dname = decl.get("name")
                if dname:
                    aliases[dname] = sname

    def rec(node: Any) -> None:
        if isinstance(node, dict):
            nt = node.get("nodeType")
            if nt == "Assignment":
                if refs_state(node.get("leftHandSide")):
                    name = _write_target_name(node, None)
                    resolved = state_name(node.get("leftHandSide"))
                    if name:
                        targets.append(resolved or name)
            elif nt == "UnaryOperation":
                if node.get("operator") in ("++", "--") and refs_state(node.get("subExpression")):
                    name = _write_target_name(node, None)
                    resolved = state_name(node.get("subExpression"))
                    if name:
                        targets.append(resolved or name)
            elif nt == "DeleteStatement":
                if refs_state(node.get("expression")):
                    name = _write_target_name(node, None)
                    resolved = state_name(node.get("expression"))
                    if name:
                        targets.append(resolved or name)
            elif nt == "FunctionCall":
                ex = node.get("expression", {})
                if node_is(ex, "MemberAccess"):
                    name = state_name(ex)
                    if name:
                        targets.append(name)
            for value in node.values():
                if value is node:
                    continue
                if isinstance(value, dict):
                    rec(value)
                elif isinstance(value, list):
                    for item in value:
                        if isinstance(item, dict):
                            rec(item)
        elif isinstance(node, list):
            for item in node:
                if isinstance(item, dict):
                    rec(item)

    rec(body)
    return targets


def collect_written_state_names(cinfo: 'ContractInfo',
                               ctx: Optional['AnalyzerContext'] = None) -> set:
    """State-variable names written anywhere in the contract, its modifiers, or
    the contracts in its inheritance closure (bases and derived)."""
    parts = [cinfo]
    if ctx is not None:
        parts = [cinfo] + ctx.bases(cinfo) + ctx.derived_of(cinfo)
    state_names = set()
    for c in parts:
        state_names |= c.state_var_names
    written = set()
    for c in parts:
        for func in c.function_nodes:
            written.update(_collect_state_write_targets(func.get("body"), state_names))
        for mod in c.modifier_nodes:
            written.update(_collect_state_write_targets(mod.get("body"), state_names))
    return written


# --------------------------------------------------------------------------
# Low-level call result tracking.
# --------------------------------------------------------------------------

def _map_calls_to_statements(body: Any) -> Dict[int, Tuple[str, Dict[str, Any]]]:
    """Map each low-level call node id -> ("discarded"|"captured"|"used", payload)."""
    mapping: Dict[int, Tuple[str, Dict[str, Any]]] = {}

    def rec(node: Any) -> None:
        if isinstance(node, dict):
            nt = node.get("nodeType")
            if nt == "ExpressionStatement":
                ex = node.get("expression")
                member = low_level_call_member(ex)
                if member and ex.get("id") is not None:
                    mapping[ex["id"]] = ("discarded", ex)
            elif nt == "VariableDeclarationStatement":
                init = node.get("initialValue")
                decls = node.get("declarations", []) or []
                if node_is(init, "TupleExpression") and decls:
                    captured = decls[0].get("name")
                    for comp in init.get("components", []) or []:
                        if low_level_call_member(comp) and comp.get("id") is not None:
                            mapping[comp["id"]] = ("captured", captured)
                elif low_level_call_member(init) and init.get("id") is not None and decls:
                    mapping[init["id"]] = ("captured", decls[0].get("name"))
            elif nt == "Assignment":
                rhs = node.get("rightHandSide")
                if low_level_call_member(rhs) and rhs.get("id") is not None:
                    lhs = node.get("leftHandSide")
                    mapping[rhs["id"]] = ("captured", lhs.get("name") if node_is(lhs, "Identifier") else None)
            for value in node.values():
                if value is node:
                    continue
                if isinstance(value, dict):
                    rec(value)
                elif isinstance(value, list):
                    for item in value:
                        if isinstance(item, dict):
                            rec(item)
        elif isinstance(node, list):
            for item in node:
                if isinstance(item, dict):
                    rec(item)

    rec(body)
    return mapping


def _assembly_references_name(body: Any, name: str) -> bool:
    """True if ``name`` is referenced inside an inline ``assembly`` block (e.g.
    ``if eq(success, 0) { revert(...) }`` after a low-level call capture)."""
    import json as _json
    for n in walk_nodes(body):
        if not node_is(n, "InlineAssembly"):
            continue
        blob = _json.dumps(n)
        if '"%s"' % name in blob:
            return True
    return False


def _identifier_referenced(body: Any, name: str) -> bool:
    for n in walk_nodes(body):
        if ident_name(n) == name:
            return True
    if name and _assembly_references_name(body, name):
        return True
    return False


def call_result_checked(body: Any, call_node: Dict[str, Any]) -> bool:
    """True if the result of a low-level call is checked or consumed."""
    mapping = _map_calls_to_statements(body)
    info = mapping.get(call_node.get("id"))
    if info is None:
        # Not a bare statement / capture -- nested inside another expression
        # (require(...), return, assignment RHS, ...) so the result is consumed.
        return True
    kind, payload = info
    if kind == "discarded":
        return False
    # captured into a bool; check it is referenced anywhere later in the body
    return bool(payload) and _identifier_referenced(body, payload)


# --------------------------------------------------------------------------
# Oracle / timestamp helpers.
# --------------------------------------------------------------------------

CHAINLINK_READS = ("latestRoundData", "getPrice", "getAnswer", "getTimestamp", "getRoundData")


def chainlink_reads(body: Any) -> List[Dict[str, Any]]:
    calls = []
    for n in walk_nodes(body):
        if node_is(n, "FunctionCall"):
            ex = n.get("expression", {})
            name = ex.get("memberName") or ex.get("name") or ""
            if name in CHAINLINK_READS:
                calls.append(n)
    return calls


def _has_staleness_check(body: Any) -> bool:
    staleness_names = ("updatedAt", "answeredInRound", "roundId", "startedAt", "updatedAt")
    for n in walk_nodes(body):
        if node_is(n, "Identifier") and n.get("name") in staleness_names:
            return True
        if node_is(n, "MemberAccess") and n.get("memberName") in staleness_names:
            return True
        # block.timestamp - updatedAt style subtraction guards
        if node_is(n, "BinaryOperation") and n.get("operator") == "-":
            left = bin_operand(n, "left")
            if node_is(left, "MemberAccess") and left.get("memberName") == "timestamp" \
                    and ident_name(index_base(left)) == "block":
                right = bin_operand(n, "right")
                if node_is(right, "Identifier") or node_is(right, "MemberAccess"):
                    return True
    return False


def _is_block_ts(node: Any) -> bool:
    if not isinstance(node, dict):
        return False
    if node.get("nodeType") == "Identifier":
        return node.get("name") == "now"
    return node.get("nodeType") == "MemberAccess" and node.get("memberName") == "timestamp" \
        and ident_name(index_base(node)) == "block"


TS_COMPARE_OPS = ("==", "!=", ">", "<", ">=", "<=")
TS_ARITH_OPS = ("+", "-", "*", "/", "%")


def _ts_kind(node: Any, chain: List[Dict[str, Any]]) -> str:
    """Classify a block.timestamp/``now`` usage from its ancestor chain: used as
    randomness (hashed or modulo), equality/comparison gating, or benign."""
    for anc in reversed(chain):
        if not isinstance(anc, dict):
            continue
        nt = anc.get("nodeType")
        if nt == "BinaryOperation":
            op = anc.get("operator")
            if op == "%":
                if _is_truncation_modulo(anc):
                    continue
                return "randomness"
            if op in TS_COMPARE_OPS:
                return "equality" if op in ("==", "!=") else "gating"
            if op in TS_ARITH_OPS:
                continue
            continue
        if nt == "FunctionCall":
            fn = anc.get("expression", {})
            fname = (fn.get("memberName") or fn.get("name") or "").lower()
            if fname in HASH_FUNCS or "hash" in fname or "keccak" in fname or "sha" in fname:
                return "randomness"
            continue
    return "benign"


def timestamp_uses(body: Any) -> List[Tuple[Dict[str, Any], str, List[Dict[str, Any]]]]:
    """Return ``(usage_node, context, ancestor_chain)`` for each block.timestamp/
    ``now`` usage, where context is one of ``randomness``, ``equality``, ``gating``
    or ``benign``."""
    results = []

    def scan(node: Any, chain: List[Dict[str, Any]]) -> None:
        if not isinstance(node, dict):
            return
        if _is_block_ts(node):
            results.append((node, _ts_kind(node, chain), chain))
            return
        for key, value in node.items():
            if value is node:
                continue
            if isinstance(value, dict):
                scan(value, chain + [node])
            elif isinstance(value, list):
                for item in value:
                    if isinstance(item, dict):
                        scan(item, chain + [node])

    scan(body, [])
    return results


# Deadline/expiry-style names indicate a transaction/authorization deadline
# check (benign), not reward-gating or exact-time logic that can be exploited.
TS_DEADLINE_RE = re.compile(r"deadline|expir|validuntil|validtil", re.IGNORECASE)
# Pause/buffer/window/timer helper calls are administrative time windows.
TS_WINDOW_CALL_RE = re.compile(r"pause|buffer|window|endtime|starttime|timer", re.IGNORECASE)


def _subtree_contains(node: Any, target: Any) -> bool:
    """True if ``target`` appears anywhere within the ``node`` subtree (identity)."""
    if node is target:
        return True
    for sub in walk_nodes(node):
        if sub is target:
            return True
    return False


def _ts_use_benign(node: Any, ts_node: Any, kind: str, chain: List[Dict[str, Any]]) -> bool:
    """Decide whether a timestamp use in ``node`` (a FunctionDefinition) is a
    benign deadline/timer/window check rather than an exploitable gating use.

    Keeps: randomness; comparisons against constants (e.g. ``timed_crowdsale``),
    and epoch/cadence gating against state arithmetic (e.g. ``governmental_survey``).
    Suppresses: comparisons against deadline/expiry-named parameters, locals or
    struct members, and pause/buffer/window helper calls."""
    if kind == "randomness":
        return False
    for anc in reversed(chain):
        if node_is(anc, "BinaryOperation") and anc.get("operator") in TS_COMPARE_OPS:
            for side in (bin_operand(anc, "left"), bin_operand(anc, "right")):
                if side is None or _subtree_contains(side, ts_node):
                    continue
                for sub in walk_nodes(side):
                    if node_is(sub, "Identifier") and TS_DEADLINE_RE.search(sub.get("name") or ""):
                        return True
                    if node_is(sub, "MemberAccess") and TS_DEADLINE_RE.search(sub.get("memberName") or ""):
                        return True
                    if node_is(sub, "FunctionCall"):
                        ex = sub.get("expression", {})
                        fname = (ex.get("memberName") or ex.get("name") or "").lower()
                        if TS_WINDOW_CALL_RE.search(fname):
                            return True
            break
    return False


HASH_FUNCS = ("keccak256", "sha3", "sha256", "ripemd160")


def _expr_has_block_dependency(node: Any) -> bool:
    """True if the expression subtree depends on block data (timestamp/number/
    difficulty/blockhash/now), i.e. is predictable by miners."""
    for n in walk_nodes(node):
        nt = n.get("nodeType")
        if nt == "Identifier":
            if n.get("name") == "now":
                return True
        elif nt == "MemberAccess":
            m = n.get("memberName")
            if m in ("timestamp", "number", "difficulty", "blockhash") and \
                    ident_name(index_base(n)) == "block":
                return True
        elif nt == "FunctionCall":
            ex = n.get("expression", {})
            if (ex.get("memberName") == "blockhash" and ident_name(index_base(ex)) == "block") \
                    or (ex.get("name") == "blockhash" and ex.get("nodeType") == "Identifier"):
                return True
    return False


def _is_truncation_modulo(n: Any) -> bool:
    """True for ``x % 2**k`` / ``x % <power of two>`` used as a type-truncation
    mask (e.g. ``uint32(block.timestamp % 2**32)``), not randomness."""
    left = bin_operand(n, "left")
    right = bin_operand(n, "right")
    for op in (left, right):
        if op is None:
            continue
        if node_is(op, "BinaryOperation") and op.get("operator") == "**":
            base = bin_operand(op, "left")
            exp = bin_operand(op, "right")
            if node_is(base, "Literal") and str(base.get("value") or "").strip() in ("2", "256", "0x100"):
                return True
        if node_is(op, "Literal"):
            v = str(op.get("value") or "").strip().lower()
            if v in ("256", "65536", "2**8", "2**16", "2**32", "2**64", "2**128", "2**256",
                     "2**224", "2**248", "2**192", "2**160", "2**96", "2**64", "2**24"):
                return True
    return False


def bad_randomness_uses(body: Any) -> List[Tuple[Dict[str, Any], str]]:
    """Predictable-randomness usages of block data. Returns ``(node, kind)`` where
    kind is one of ``blockhash``, ``hash``, ``modulo``, ``difficulty``."""
    out: List[Tuple[Dict[str, Any], str]] = []

    def is_blockhash_call(n: Any) -> bool:
        if not node_is(n, "FunctionCall"):
            return False
        ex = n.get("expression", {})
        if ex.get("nodeType") == "Identifier" and ex.get("name") == "blockhash":
            return True
        return ex.get("nodeType") == "MemberAccess" and ex.get("memberName") == "blockhash" \
            and ident_name(index_base(ex)) == "block"

    def is_hash_call(n: Any) -> bool:
        if not node_is(n, "FunctionCall"):
            return None
        ex = n.get("expression", {})
        return (ex.get("memberName") or ex.get("name") or "").lower() in HASH_FUNCS

    for n in walk_nodes(body):
        nt = n.get("nodeType")
        if is_blockhash_call(n):
            out.append((n, "blockhash"))
        elif nt == "FunctionCall" and is_hash_call(n):
            if any(_expr_has_block_dependency(a) for a in (n.get("arguments") or [])):
                out.append((n, "hash"))
        elif nt == "BinaryOperation" and n.get("operator") == "%":
            if _is_truncation_modulo(n):
                continue
            if _expr_has_block_dependency(bin_operand(n, "left")) or _expr_has_block_dependency(bin_operand(n, "right")):
                out.append((n, "modulo"))
        elif nt == "MemberAccess" and n.get("memberName") == "difficulty" \
                and ident_name(index_base(n)) == "block":
            out.append((n, "difficulty"))
    return out


# --------------------------------------------------------------------------
# Reentrancy / MEV protection helpers.
# --------------------------------------------------------------------------

def function_reentrancy_guarded(ctx: 'AnalyzerContext', cinfo: 'ContractInfo',
                                func: Dict[str, Any]) -> bool:
    for mod in ctx.applied_modifiers(cinfo, func):
        if REENTRANCY_GUARD_RE.search((mod.get("name") or "").lower()):
            return True
        if modifier_sets_lock(mod):
            return True
    return False


def _internal_call_target(node: Any, cinfo: 'ContractInfo',
                          ctx: 'AnalyzerContext') -> Optional[Dict[str, Any]]:
    """If ``node`` is a call to a same-contract function (direct or via ``this``),
    return that FunctionDefinition, else None."""
    if not node_is(node, "FunctionCall"):
        return None
    ex = node.get("expression", {})
    name = None
    if node_is(ex, "Identifier"):
        name = ex.get("name")
    elif node_is(ex, "MemberAccess") and ident_name(ex.get("expression")) == "this":
        name = ex.get("memberName")
    if not name:
        return None
    funcs = list(cinfo.function_nodes)
    for base in ctx.bases(cinfo) if ctx else []:
        funcs.extend(base.function_nodes)
    for fn in funcs:
        if fn.get("name") == name:
            return fn
    return None


_reentry_call_cache: Dict[int, bool] = {}


def _function_has_value_call(node: Any) -> bool:
    """True if the function body contains a low-level ``.call`` (a reentry vector)."""
    if node is None:
        return False
    nid = node.get("id")
    if nid is not None and nid in _reentry_call_cache:
        return _reentry_call_cache[nid]
    if node.get("body") is None:
        return False
    for n in walk_nodes(node.get("body")):
        if low_level_call_member(n) == "call":
            if nid is not None:
                _reentry_call_cache[nid] = True
            return True
    if nid is not None:
        _reentry_call_cache[nid] = False
    return False


MATH_MEMBER_NAMES = {
    "add", "sub", "mul", "div", "mod", "ceildiv", "avg", "min", "max",
    "abs", "exp", "sqrt", "pow", "wmul", "wdiv", "rmul", "rdiv", "floor",
    "ceil", "round", "sqrrt", "logn", "to128", "to256", "per", "toint", "touint",
}

# OpenZeppelin SafeCast-style casts (``value.toInt256()``, ``x.toUint128()``).
# These are pure library conversions on the receiver, never external calls.
_SAFE_CAST_RE = re.compile(r"^to(?:int|uint)(?:8|16|32|64|128|256)?$", re.IGNORECASE)


def _is_math_member_call(node: Any) -> bool:
    """True for SafeMath-style library calls invoked as ``value.func(...)``."""
    if not node_is(node, "FunctionCall"):
        return False
    ex = node.get("expression", {})
    if not node_is(ex, "MemberAccess"):
        return False
    name = ex.get("memberName") or ""
    return name.lower() in MATH_MEMBER_NAMES or bool(_SAFE_CAST_RE.match(name))


QUERY_MEMBER_RE = re.compile(
    r"^(?i:is|has|can|get|check|view|peek|read|query|compute|calculate|"
    r"ownerof|balanceof|support|encode|decode|delegate|slot|byte|pad|abi|"
    r"min|max|operator|address|owner|length|gas)(?=[A-Z0-9_])"
    r"|(?i:allowed|allowance|approved|rate|price|fee|interest|balances?)\b",
)


def _is_query_member_call(node: Any) -> bool:
    """True for calls to view/query-style members (preflight access checks,
    oracle/rate reads, getters) on a contract -- these are not reentry vectors
    that move value/tokens."""
    if not node_is(node, "FunctionCall"):
        return False
    ex = node.get("expression", {})
    if not node_is(ex, "MemberAccess"):
        return False
    return bool(QUERY_MEMBER_RE.search(ex.get("memberName") or ""))


def _high_level_state_call(node: Any, cinfo: 'ContractInfo', aliases: Optional[set] = None) -> bool:
    """True if ``node`` is a high-level member call (``token.transfer(...)``,
    ``Channels[id].token.method(...)``) whose receiver is a contract/address
    stored in contract state, i.e. a potentially malicious external target."""
    if not node_is(node, "FunctionCall"):
        return False
    if _is_math_member_call(node):
        return False
    if _is_query_member_call(node):
        return False
    ex = node.get("expression", {})
    if not node_is(ex, "MemberAccess"):
        return False
    if ex.get("memberName") in LOW_LEVEL_CALLS:
        return False
    base = ex.get("expression")
    if not isinstance(base, dict):
        return False
    if _expr_contains_this(base):
        return False
    if not _target_refs_state(base, cinfo, aliases):
        return False
    return True


def _modifier_external_calls(ctx: 'AnalyzerContext', cinfo: 'ContractInfo',
                             func: Any) -> List[Dict[str, Any]]:
    """External call nodes inside non-auth/non-guard modifiers applied to
    ``func``. Calls made from a modifier run before the function body, so they
    are reentry points even though they are not lexically inside the body."""
    calls: List[Dict[str, Any]] = []
    for mod in ctx.applied_modifiers(cinfo, func):
        mname = (mod.get("name") or "").lower()
        if REENTRANCY_GUARD_RE.search(mname) or modifier_sets_lock(mod):
            continue
        if AUTH_HELPER_RE.search(mname):
            continue
        mbody = mod.get("body") or mod.get("body_")
        for n in walk_nodes(mbody):
            if not node_is(n, "FunctionCall"):
                continue
            if _is_math_member_call(n) or _is_query_member_call(n):
                continue
            ex = n.get("expression", {})
            if not node_is(ex, "MemberAccess"):
                continue
            if _expr_contains_this(ex.get("expression")):
                continue
            tgt = _internal_call_target(n, cinfo, ctx)
            if tgt is not None and not _function_has_value_call(tgt):
                continue
            calls.append(n)
    return calls


def reentrancy_events(ctx: 'AnalyzerContext', cinfo: 'ContractInfo',
                      body: Any, func: Any = None) -> List[Tuple[str, Dict[str, Any]]]:
    """Pre-order ``("write"|"call", node)`` events including low-level calls,
    same-contract internal calls whose body contains a low-level ``.call``,
    high-level calls to state-stored contracts, and (when ``func`` is given)
    external calls made from the function's modifiers."""
    out: List[Tuple[str, Dict[str, Any]]] = []
    aliases = _collect_storage_aliases(body, cinfo)
    if func is not None:
        for n in _modifier_external_calls(ctx, cinfo, func):
            out.append(("call", n))

    def rec(node: Any) -> None:
        if isinstance(node, dict):
            nt = node.get("nodeType")
            if nt == "Assignment":
                if _target_refs_state(node.get("leftHandSide"), cinfo, aliases):
                    out.append(("write", node))
            elif nt == "UnaryOperation":
                if node.get("operator") in ("++", "--") and _target_refs_state(node.get("subExpression"), cinfo, aliases):
                    out.append(("write", node))
            elif nt == "DeleteStatement":
                if _target_refs_state(node.get("expression"), cinfo, aliases):
                    out.append(("write", node))
            elif nt == "FunctionCall":
                if low_level_call_member(node) == "call":
                    out.append(("call", node))
                elif _high_level_state_call(node, cinfo, aliases):
                    out.append(("call", node))
                else:
                    tgt = _internal_call_target(node, cinfo, ctx)
                    if tgt is not None and _function_has_value_call(tgt):
                        out.append(("call", node))
            for value in node.values():
                if value is node:
                    continue
                if isinstance(value, dict):
                    rec(value)
                elif isinstance(value, list):
                    for item in value:
                        if isinstance(item, dict):
                            rec(item)
        elif isinstance(node, list):
            for item in node:
                if isinstance(item, dict):
                    rec(item)

    rec(body)
    return out


def _reads_price(body: Any) -> bool:
    price_tokens = ("price", "rate", "oracle", "reserve", "quote", "spot")
    for n in walk_nodes(body):
        if node_is(n, "Identifier"):
            low = n.get("name", "").lower()
            if any(t in low for t in price_tokens):
                return True
        if node_is(n, "FunctionCall"):
            ex = n.get("expression", {})
            name = (ex.get("memberName") or ex.get("name") or "").lower()
            if name in ("latestrounddata", "getreserves", "getprice", "getquote"):
                return True
    return False


def _moves_tokens(body: Any) -> bool:
    for n in walk_nodes(body):
        if node_is(n, "FunctionCall"):
            member = low_level_call_member(n)
            if member in ("call", "delegatecall"):
                # only counts as moving tokens if value is attached
                ex = n.get("expression", {})
                if node_is(ex, "FunctionCallOptions"):
                    return True
                if node_is(ex, "MemberAccess"):
                    target = ex.get("expression")
                    if _expr_mentions_msg_sender(target):
                        # bare .call on an address still may move value in data; treat call as token-moving
                        return True
            ex = n.get("expression", {})
            name = (ex.get("memberName") or ex.get("name") or "").lower()
            if name in ("transfer", "transferfrom", "send", "_transfer", "mint", "burn", "safeTransfer", "safeTransferFrom"):
                return True
        if node_is(n, "Assignment"):
            lhs = n.get("leftHandSide", {})
            if node_is(lhs, "Identifier"):
                low = lhs.get("name", "").lower()
                if low in ("balance", "balances", "totalSupply") or "balance" in low:
                    return True
            if node_is(lhs, "IndexAccess"):
                base = index_base(lhs)
                if node_is(base, "Identifier") and "balance" in base.get("name", "").lower():
                    return True
    return False


MEV_PROTECTION_PARAM_RE = re.compile(
    r"(min|slippage|deadline|limit|tolerance|sanity|desired|acceptable|"
    r"amountout|minout|maxout|minimum)"
)


def function_has_mev_protection(func: Dict[str, Any]) -> bool:
    for p in func.get("parameters", {}).get("parameters", []) or []:
        if MEV_PROTECTION_PARAM_RE.search((p.get("name") or "").lower()):
            return True
    body = func.get("body")
    for n in walk_nodes(body):
        if node_is(n, "BinaryOperation") and n.get("operator") in (">=", ">", "<=", "<", "=="):
            left = bin_operand(n, "left")
            right = bin_operand(n, "right")
            names = []
            for side in (left, right):
                for sub in walk_nodes(side):
                    if node_is(sub, "Identifier"):
                        names.append(sub.get("name", "").lower())
            if any(("out" in x or "min" in x or "slippage" in x or "deadline" in x or "timestamp" in x) for x in names):
                return True
            if n.get("operator") == "==" and any(
                ("price" in x or "target" in x or "expected" in x or "exact" in x) for x in names
            ):
                return True
    return False


# --------------------------------------------------------------------------
# Replay-protection helpers.
# --------------------------------------------------------------------------

REPLAY_STATE_RE = re.compile(
    r"(nonce|used|consumed|spent|deadline|expir|replay|claimed|processed|signatures|seen)"
)


def function_has_replay_protection(ctx: Optional['AnalyzerContext'], cinfo: 'ContractInfo',
                                   func: Dict[str, Any]) -> bool:
    parts = [cinfo] + (ctx.bases(cinfo) if ctx else [])
    for c in parts:
        for sv in c.state_vars:
            if REPLAY_STATE_RE.search((sv.get("name") or "").lower()):
                return True
    body = func.get("body")
    for n in walk_nodes(body):
        if node_is(n, "Identifier") and REPLAY_STATE_RE.search((n.get("name") or "").lower()):
            return True
        if node_is(n, "MemberAccess") and REPLAY_STATE_RE.search((n.get("memberName") or "").lower()):
            return True
    return False


# --------------------------------------------------------------------------
# Privileged / sensitive behavior (access control).
# --------------------------------------------------------------------------

PRIVILEGED_EXACT = {
    "pause", "unpause", "withdraw", "mint", "burn", "destroy", "kill", "upgrade",
    "transferOwnership", "renounceOwnership", "grant", "revoke", "freeze",
    "unfreeze", "seize", "liquidate", "finalize", "migrate", "drain", "sweep",
    "distribute", "collect", "recover", "claim", "emergency", "invalidate",
    "collectFees", "harvest", "settle", "redeem", "sweepToken", "rescue",
    "setPendingOwner", "acceptOwnership",
}

PRIVILEGED_PREFIX = (
    "set", "update", "delete", "add", "remove", "change", "adjust", "toggle",
    "activate", "deactivate", "enable", "disable", "reset", "clear", "put",
)

PRIVILEGED_CONTAINS = (
    "whitelist", "blacklist", "allowlist", "blocklist", "upgrade", "onlyowner",
    "onlyadmin", "onlyrole", "onlygovern", "onlyoperator", "onlyvault", "onlygateway",
)

# DEX router / pool user actions that look privileged by prefix but are open
# to any caller (addLiquidity, removeLiquidity, swap*, quote, route, trade).
USER_ACTION_PREFIX = (
    "swap", "route", "quote", "trade",
)

USER_ACTION_CONTAINS = (
    "liquidity", "position",
)


def function_name_is_privileged(name: str) -> bool:
    low = name.lower()
    if low.startswith(USER_ACTION_PREFIX):
        return False
    for token in USER_ACTION_CONTAINS:
        if token in low:
            return False
    if low in PRIVILEGED_EXACT:
        return True
    if low.startswith(PRIVILEGED_PREFIX):
        return True
    for token in PRIVILEGED_CONTAINS:
        if token in low:
            return True
    return False


def _write_is_per_user(node: Dict[str, Any]) -> bool:
    """True if a write target is a per-``msg.sender`` mapping slot."""
    target = node.get("leftHandSide") or node.get("subExpression") or node.get("expression")
    if node_is(target, "IndexAccess"):
        index = index_value(target)
        if _expr_mentions_msg_sender(index):
            return True
        base = target
        while node_is(base, "IndexAccess") or node_is(base, "MemberAccess"):
            inner = index_base(base)
            if inner is None:
                break
            base = inner
        bname = (ident_name(base) or "").lower()
        if any(tok in bname for tok in ("approval", "approvals", "allowance", "allowances", "allowed")):
            return True
    return False


def _transfer_recipient(call: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Resolve the recipient of a transfer/send-style call, or None if unknown."""
    ex = call.get("expression", {})
    member = (ex.get("memberName") or "").lower()
    args = call.get("arguments") or []
    if member in ("send",):
        if len(args) == 1:
            return ex.get("expression")
        return None
    if member in ("transfer", "safeTransfer"):
        if len(args) == 1:
            return ex.get("expression")
        if len(args) >= 2:
            return args[0]
        return None
    if member in ("transferfrom", "safetransferfrom"):
        if len(args) >= 2:
            return args[1]
        return None
    if "transfer" in member and len(args) >= 2:
        return args[0]
    return None


def function_is_sensitive(ctx: 'AnalyzerContext', cinfo: 'ContractInfo',
                          func: Dict[str, Any]) -> bool:
    """True when a function looks like a privileged operation (name heuristic) and
    actually performs something sensitive (writes contract-global state or moves
    value to an address that is not provably ``msg.sender``)."""
    if not function_name_is_privileged(func.get("name") or ""):
        return False
    body = func.get("body")
    moves_to_user = False
    for n in walk_nodes(body):
        if node_is(n, "FunctionCall"):
            ex = n.get("expression", {})
            name = ex.get("memberName") or ex.get("name") or ""
            if "transfer" in name.lower() or name == "send":
                recipient = _transfer_recipient(n)
                if recipient is not None:
                    if _expr_mentions_msg_sender(recipient):
                        moves_to_user = True
                    else:
                        return True
            member = low_level_call_member(n)
            if member in ("call", "delegatecall"):
                target = call_target(n)
                if target is not None and not _expr_mentions_msg_sender(target):
                    return True
    if moves_to_user:
        return False
    for kind, node in collect_state_events(body, cinfo):
        if kind == "write":
            name = (_write_target_name(node, cinfo) or "").lower()
            if "total" in name or "supply" in name or "count" in name:
                continue
            if _write_is_per_user(node):
                continue
            return True
    return False


# --------------------------------------------------------------------------
# Contract / project index.
# --------------------------------------------------------------------------

class ContractInfo:
    __slots__ = (
        "name", "id", "node", "kind", "is_interface", "is_abstract", "is_library",
        "state_vars", "state_var_names", "function_nodes", "modifier_nodes",
    )

    def __init__(self, node: Dict[str, Any]):
        self.name = node.get("name", "")
        self.id = node.get("id")
        self.node = node
        self.kind = node.get("contractKind", "")
        self.is_interface = self.kind == "interface"
        self.is_abstract = bool(node.get("abstract"))
        self.is_library = self.kind == "library"
        self.state_vars: List[Dict[str, Any]] = []
        self.state_var_names: set = set()
        self.function_nodes: List[Dict[str, Any]] = []
        self.modifier_nodes: List[Dict[str, Any]] = []
        for n in node.get("nodes", []) or []:
            nt = n.get("nodeType")
            if nt == "FunctionDefinition":
                self.function_nodes.append(n)
            elif nt == "ModifierDefinition":
                self.modifier_nodes.append(n)
            elif nt == "VariableDeclaration" and n.get("stateVariable"):
                self.state_vars.append(n)
                self.state_var_names.add(n.get("name"))


class AnalyzerContext:
    """Index over every contract in the compilation, with inheritance resolution."""

    def __init__(self, ast_data: Dict[str, Any]):
        self.contracts_by_id: Dict[int, ContractInfo] = {}
        self.contracts_by_name: Dict[str, List[ContractInfo]] = {}
        self.func_id_to_contract: Dict[int, ContractInfo] = {}
        self.mod_id_to_contract: Dict[int, ContractInfo] = {}
        self._build(ast_data)
        self._build_derived()

    def _build(self, ast_data: Dict[str, Any]) -> None:
        sources = ast_data.get("sources", {})
        if not sources and ast_data.get("ast"):
            sources = {"input.sol": ast_data}
        for info in sources.values():
            if not isinstance(info, dict):
                continue
            ast = info.get("ast")
            if not ast:
                continue
            for node in ast.get("nodes", []) or []:
                if node.get("nodeType") != "ContractDefinition":
                    continue
                cinfo = ContractInfo(node)
                self.contracts_by_id[cinfo.id] = cinfo
                self.contracts_by_name.setdefault(cinfo.name, []).append(cinfo)
                for f in cinfo.function_nodes:
                    if f.get("id") is not None:
                        self.func_id_to_contract[f["id"]] = cinfo
                for m in cinfo.modifier_nodes:
                    if m.get("id") is not None:
                        self.mod_id_to_contract[m["id"]] = cinfo

    def _build_derived(self) -> None:
        """Index direct derived contracts per base contract id."""
        self.derived_by_id: Dict[int, List[ContractInfo]] = {}
        for cinfo in self.contracts_by_id.values():
            for base in cinfo.node.get("baseContracts", []) or []:
                name = base.get("baseName", {}).get("name")
                for b in self.contracts_by_name.get(name, []):
                    self.derived_by_id.setdefault(b.id, []).append(cinfo)

    def derived_of(self, cinfo: ContractInfo) -> List[ContractInfo]:
        """Descendant contracts (DFS, de-duplicated), including indirect ones."""
        result: List[ContractInfo] = []
        seen = {cinfo.id}

        def walk(c: ContractInfo) -> None:
            for d in self.derived_by_id.get(c.id, []):
                if d.id in seen:
                    continue
                seen.add(d.id)
                result.append(d)
                walk(d)

        walk(cinfo)
        return result

    def contract_for_function(self, func: Dict[str, Any]) -> Optional[ContractInfo]:
        return self.func_id_to_contract.get(func.get("id"))

    def contract_for_node(self, node: Dict[str, Any]) -> Optional[ContractInfo]:
        cid = node.get("id")
        return self.contracts_by_id.get(cid)

    def contract_by_name(self, name: str) -> Optional[ContractInfo]:
        lst = self.contracts_by_name.get(name)
        return lst[0] if lst else None

    def bases(self, cinfo: ContractInfo) -> List[ContractInfo]:
        """Ancestor contracts (DFS, de-duplicated)."""
        result: List[ContractInfo] = []
        seen = {cinfo.id}

        def walk(c: ContractInfo) -> None:
            for base in c.node.get("baseContracts", []) or []:
                name = base.get("baseName", {}).get("name")
                for b in self.contracts_by_name.get(name, []):
                    if b.id in seen:
                        continue
                    seen.add(b.id)
                    result.append(b)
                    walk(b)

        walk(cinfo)
        return result

    def applied_modifiers(self, cinfo: ContractInfo,
                          func: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Resolve the modifiers applied to ``func`` to their definition nodes,
        including inherited ones."""
        result: List[Dict[str, Any]] = []
        mods = [m for m in (func.get("modifiers") or []) if node_is(m.get("modifierName"), "Identifier")]
        if not mods:
            mods = [m for m in (func.get("modifiers") or []) if isinstance(m, dict)]
        for m in mods:
            mn = m.get("modifierName", {})
            name = mn.get("name")
            mid = mn.get("referencedDeclaration")
            found = None
            if mid is not None:
                owner = self.mod_id_to_contract.get(mid)
                if owner is not None:
                    for mod in owner.modifier_nodes:
                        if mod.get("id") == mid:
                            found = mod
                            break
            if found is None and name:
                for mod in [mod for c in [cinfo] + self.bases(cinfo) for mod in c.modifier_nodes]:
                    if mod.get("name") == name:
                        found = mod
                        break
            if found is not None:
                result.append(found)
        return result

    def function_has_guard(self, cinfo: ContractInfo, func: Dict[str, Any]) -> bool:
        for mod in self.applied_modifiers(cinfo, func):
            if modifier_is_guard(mod):
                return True
        return block_has_auth(func.get("body"))

    def stateful_bases(self, cinfo: ContractInfo) -> List[ContractInfo]:
        return [
            b for b in self.bases(cinfo)
            if any(not _is_constant_var(sv) for sv in b.state_vars)
        ]
