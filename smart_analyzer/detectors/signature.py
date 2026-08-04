"""
Signature replay vulnerability detector.

This module provides detectors for signature replay vulnerabilities using the
super-pythonic approach.

A signature verification is only reported when the surrounding contract/function
shows no evidence of replay protection (nonce/used-signature tracking, deadlines,
or EIP-712 style replay-proofs).
"""

from typing import Dict, Any, List

from ..utils import detector, parse_src
from ..findings import SignatureReplayFinding, Severity
from ..context import (
    get_analysis_context, walk_nodes, node_is, ident_name,
    function_has_replay_protection,
)

_MEMBER_SIGNATURE_VERIFIERS = (
    "recover", "isValidSignatureNow", "isValidSignature",
    "isValidERC1271SignatureNow",
)

_SIGNATURE_HELPERS = ("ECDSA", "ECDSAUpgradeable", "ECDSAWithdraw")


def _parse_line(node: Dict[str, Any], file_path: str) -> Any:
    return parse_src(node.get("src"), file_path)


def _find_signature_verification(node: Dict[str, Any]) -> bool:
    fname = (node.get("name") or "").lower()
    if "signature" in fname or fname.startswith("sign"):
        return True
    for n in walk_nodes(node.get("body")):
        if not node_is(n, "FunctionCall"):
            continue
        ex = n.get("expression", {})
        if ident_name(ex) == "ecrecover":
            return True
        if node_is(ex, "MemberAccess"):
            member = ex.get("memberName", "")
            if member in _MEMBER_SIGNATURE_VERIFIERS:
                return True
            if member.lower() == "recover" and ex.get("expression", {}).get("name") in _SIGNATURE_HELPERS:
                return True
        else:
            name = ex.get("name") or ex.get("memberName") or ""
            if "signature" in name.lower():
                return True
    return False


@detector("signature_replay", "✍️ Signature Replay", "Detects signature replay vulnerabilities", category="security")
def detect_signature_replay(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect signature verification without replay protection."""
    if node.get("nodeType") != "FunctionDefinition":
        return

    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_interface:
        return
    if function_has_replay_protection(ctx, cinfo, node):
        return
    if not _find_signature_verification(node):
        return

    findings.append(SignatureReplayFinding(
        message="Signature verification detected without replay protection. This "
                "allows signature reuse attacks. Add nonce/hash tracking or "
                "timestamp validation.",
        severity=Severity.CRITICAL,
        line_number=_parse_line(node, file_path),
        file_path=file_path,
        source_code=node.get("src")
    ))


@detector("signature_in_loop", "🔄 Signature in Loop", "Detects signature verification in loops", category="security")
def detect_signature_in_loop(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect signature verification in loops."""
    if node.get("nodeType") in ("ForStatement", "WhileStatement"):
        node_str = str(node)
        if any(keyword in node_str for keyword in ["ecrecover", "ECDSA", "signature", "recover"]):
            findings.append(SignatureReplayFinding(
                message="Signature verification in loop detected. Ensure each "
                        "iteration uses unique data to prevent replay.",
                severity=Severity.HIGH,
                line_number=_parse_line(node, file_path),
                file_path=file_path,
                source_code=node.get("src")
            ))
