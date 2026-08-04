"""
Reentrancy vulnerability detector.

This module provides detectors for reentrancy vulnerabilities using the
super-pythonic approach.

Reentrancy is only reported when a low-level external call is followed by a state
modification within the same function (check-effects-interactions violation) and
the function does not carry a reentrancy guard.  Unchecked calls are only reported
when the boolean result of a low-level call is neither stored nor validated.
"""

from typing import Dict, Any, List

from ..utils import detector, parse_src
from ..findings import ReentrancyFinding, UncheckedCallFinding, Severity
from ..context import (
    get_analysis_context, walk_nodes,
    low_level_call_member, call_target, _expr_contains_this,
    collect_state_events, call_result_checked, function_reentrancy_guarded,
    reentrancy_events,
)


def _parse_line(node: Dict[str, Any], file_path: str) -> Any:
    return parse_src(node.get("src"), file_path)


@detector("reentrancy", "🔄 Reentrancy", "Detects reentrancy vulnerabilities", category="security")
def detect_reentrancy(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect potential reentrancy via external calls that violate the
    checks-effects-interactions ordering."""
    if node.get("nodeType") != "FunctionDefinition":
        return

    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None:
        return

    if function_reentrancy_guarded(ctx, cinfo, node):
        return

    body = node.get("body")
    events = reentrancy_events(ctx, cinfo, body, func=node)
    call_indices = [i for i, (k, _) in enumerate(events) if k == "call"]
    write_indices = [i for i, (k, _) in enumerate(events) if k == "write"]

    for ci in call_indices:
        _, call_node = events[ci]
        target = call_target(call_node)
        if target is not None and _expr_contains_this(target):
            continue
        if any(wi > ci for wi in write_indices):
            findings.append(ReentrancyFinding(
                message="Potential reentrancy: external call is followed by a state "
                        "modification (checks-effects-interactions violation).",
                severity=Severity.HIGH,
                line_number=_parse_line(call_node, file_path),
                file_path=file_path,
                source_code=call_node.get("src")
            ))
            return


@detector("unchecked_call", "⚠️ Unchecked Call", "Detects unchecked external calls without require()", category="security")
def detect_unchecked_call(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect low-level external calls whose boolean result is discarded or never
    validated."""
    if node.get("nodeType") != "FunctionDefinition":
        return

    body = node.get("body")
    seen = set()
    for n in walk_nodes(body):
        if low_level_call_member(n) is None:
            continue
        if n.get("id") in seen:
            continue
        seen.add(n.get("id"))
        if not call_result_checked(body, n):
            findings.append(UncheckedCallFinding(
                message="Low-level call result is not checked; a failed call may go "
                        "unnoticed.",
                severity=Severity.MEDIUM,
                line_number=_parse_line(n, file_path),
                file_path=file_path,
                source_code=n.get("src")
            ))
