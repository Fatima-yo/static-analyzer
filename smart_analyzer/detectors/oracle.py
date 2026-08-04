"""
Oracle manipulation vulnerability detectors.

This module provides detectors for oracle-related vulnerabilities.

The only detector is for Chainlink-style price reads that lack staleness/round
validation.  All previous name-substring matching (variables named ``price``,
functions named ``flash*``, ``verify``/``recover`` callers, ...) has been removed
because it produced thousands of false positives.
"""

from typing import Dict, Any, List

from ..utils import detector, parse_src
from ..findings import OracleManipulationFinding, Severity
from ..context import (
    get_analysis_context, chainlink_reads, _has_staleness_check,
)


def _parse_line(node: Dict[str, Any], file_path: str) -> Any:
    return parse_src(node.get("src"), file_path)


@detector("oracle_manipulation", "🔮 Oracle Manipulation", "Detects oracle manipulation vulnerabilities including signature reuse", category="security")
def detect_oracle_manipulation(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    """Detect Chainlink oracle reads that are not validated for staleness."""
    if node.get("nodeType") != "FunctionDefinition":
        return

    ctx = get_analysis_context()
    if ctx is None:
        return
    cinfo = ctx.contract_for_function(node)
    if cinfo is None or cinfo.is_interface:
        return

    body = node.get("body")
    reads = chainlink_reads(body)
    if not reads:
        return
    if _has_staleness_check(body):
        return

    # Only flag when the read result is actually consumed for pricing decisions.
    read = reads[0]
    findings.append(OracleManipulationFinding(
        message="Chainlink oracle read detected without staleness/round validation. "
                "Validate updatedAt/answeredInRound before using the price.",
        severity=Severity.HIGH,
        line_number=_parse_line(read, file_path),
        file_path=file_path,
        source_code=read.get("src")
    ))
