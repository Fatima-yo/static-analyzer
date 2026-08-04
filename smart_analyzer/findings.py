"""
Findings system for the Solidity Static Analyzer.

This module provides the core classes for representing and collecting
vulnerability findings in a super-pythonic way.
"""

from dataclasses import dataclass, field
from typing import List, Iterator, Optional, Dict, Any
from enum import Enum
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.text import Text
import os


class Severity(Enum):
    """Severity levels for findings."""
    LOW = "LOW"
    MEDIUM = "MEDIUM"
    HIGH = "HIGH"
    CRITICAL = "CRITICAL"


@dataclass
class Finding:
    """Base class for all vulnerability findings."""
    
    message: str
    severity: Severity
    type: str = ""  # Make type optional with default empty string
    line_number: Optional[int] = None
    file_path: Optional[str] = None
    source_code: Optional[str] = None
    context: Dict[str, Any] = field(default_factory=dict)
    
    def __str__(self) -> str:
        """Beautiful string representation of the finding."""
        line_info = f" (line {self.line_number})" if self.line_number else ""
        severity_color = {
            Severity.LOW: "blue",
            Severity.MEDIUM: "yellow", 
            Severity.HIGH: "red",
            Severity.CRITICAL: "bold red"
        }
        
        return f"[{severity_color[self.severity]}]{self.severity.value}[/{severity_color[self.severity]}] {self.type}: {self.message}{line_info}"
    
    def __repr__(self) -> str:
        """Detailed representation for debugging."""
        return f"Finding(type='{self.type}', severity={self.severity.value}, line={self.line_number})"


@dataclass
class ReentrancyFinding(Finding):
    """Specific finding for reentrancy vulnerabilities."""
    
    def __post_init__(self):
        self.type = "Reentrancy"
        if not self.severity:
            self.severity = Severity.HIGH


@dataclass
class SignatureReplayFinding(Finding):
    """Specific finding for signature replay vulnerabilities."""
    
    def __post_init__(self):
        self.type = "Signature Replay"
        if not self.severity:
            self.severity = Severity.CRITICAL


@dataclass
class IntegerOverflowFinding(Finding):
    """Specific finding for integer overflow vulnerabilities."""
    
    def __post_init__(self):
        self.type = "Integer Overflow"
        if not self.severity:
            self.severity = Severity.MEDIUM


@dataclass
class TxOriginFinding(Finding):
    """Specific finding for tx.origin usage."""
    
    def __post_init__(self):
        self.type = "tx.origin Usage"
        if not self.severity:
            self.severity = Severity.MEDIUM


@dataclass
class UncheckedCallFinding(Finding):
    """Specific finding for unchecked external calls."""
    
    def __post_init__(self):
        self.type = "Unchecked Call"
        if not self.severity:
            self.severity = Severity.MEDIUM


@dataclass
class OracleManipulationFinding(Finding):
    """Specific finding for oracle manipulation vulnerabilities."""
    
    def __post_init__(self):
        self.type = "Oracle Manipulation"
        if not self.severity:
            self.severity = Severity.HIGH


@dataclass
class AccessControlFinding(Finding):
    def __post_init__(self):
        self.type = "access_control"
        if not self.severity:
            self.severity = Severity.HIGH

@dataclass
class FlashLoanFinding(Finding):
    def __post_init__(self):
        self.type = "Flash Loan"
        if not self.severity:
            self.severity = Severity.HIGH

@dataclass
class FrontRunningFinding(Finding):
    def __post_init__(self):
        self.type = "Front Running"
        if not self.severity:
            self.severity = Severity.MEDIUM

@dataclass
class TimestampFinding(Finding):
    def __post_init__(self):
        self.type = "Timestamp Dependence"
        if not self.severity:
            self.severity = Severity.MEDIUM

@dataclass
class BadRandomnessFinding(Finding):
    def __post_init__(self):
        self.type = "Bad Randomness"
        if not self.severity:
            self.severity = Severity.MEDIUM


@dataclass
class DoSFinding(Finding):
    def __post_init__(self):
        self.type = "Denial of Service"
        if not self.severity:
            self.severity = Severity.HIGH

@dataclass
class GasLimitFinding(Finding):
    def __post_init__(self):
        self.type = "Gas Limit"
        if not self.severity:
            self.severity = Severity.MEDIUM

@dataclass
class DelegateCallFinding(Finding):
    def __post_init__(self):
        self.type = "Delegate Call"
        if not self.severity:
            self.severity = Severity.HIGH

@dataclass
class EventFinding(Finding):
    def __post_init__(self):
        self.type = "event"
        if not self.severity:
            self.severity = Severity.LOW

@dataclass
class UninitializedFinding(Finding):
    def __post_init__(self):
        self.type = "Uninitialized Variable"
        if not self.severity:
            self.severity = Severity.MEDIUM

@dataclass
class InterfaceFinding(Finding):
    def __post_init__(self):
        self.type = "Interface Usage"
        if not self.severity:
            self.severity = Severity.MEDIUM

@dataclass
class ZeroAddressFinding(Finding):
    def __post_init__(self):
        self.type = "Zero Address"
        if not self.severity:
            self.severity = Severity.MEDIUM

@dataclass
class TypeCastFinding(Finding):
    def __post_init__(self):
        self.type = "Type Cast"
        if not self.severity:
            self.severity = Severity.MEDIUM

@dataclass
class ModifierFinding(Finding):
    def __post_init__(self):
        self.type = "Modifier Usage"
        if not self.severity:
            self.severity = Severity.HIGH

@dataclass
class RedundantCodeFinding(Finding):
    def __post_init__(self):
        self.type = "Redundant Code"
        if not self.severity:
            self.severity = Severity.LOW

@dataclass
class ErrorMessageFinding(Finding):
    def __post_init__(self):
        self.type = "Error Message"
        if not self.severity:
            self.severity = Severity.LOW

@dataclass
class HardcodedFinding(Finding):
    def __post_init__(self):
        self.type = "Hardcoded Value"
        if not self.severity:
            self.severity = Severity.LOW

@dataclass
class DocumentationFinding(Finding):
    def __post_init__(self):
        self.type = "Documentation"
        if not self.severity:
            self.severity = Severity.LOW

@dataclass
class NamingFinding(Finding):
    def __post_init__(self):
        self.type = "Naming Convention"
        if not self.severity:
            self.severity = Severity.LOW

@dataclass
class MEVFinding(Finding):
    def __post_init__(self):
        self.type = "MEV"
        if not self.severity:
            self.severity = Severity.MEDIUM

@dataclass
class CrossFunctionFinding(Finding):
    def __post_init__(self):
        self.type = "cross_function"
        if not self.severity:
            self.severity = Severity.HIGH

@dataclass
class StorageCollisionFinding(Finding):
    def __post_init__(self):
        self.type = "Storage Collision"
        if not self.severity:
            self.severity = Severity.MEDIUM

@dataclass
class UpgradeFinding(Finding):
    def __post_init__(self):
        self.type = "Upgrade Pattern"
        if not self.severity:
            self.severity = Severity.HIGH

@dataclass
class CrossChainFinding(Finding):
    def __post_init__(self):
        self.type = "Cross Chain"
        if not self.severity:
            self.severity = Severity.HIGH


@dataclass
class ValueFlowFinding(Finding):
    """Balance-accounting / value-flow mismatch where a counterparty can
    redirect funds (fee-on-transfer, rebasing or attacker-chosen tokens)."""
    def __post_init__(self):
        self.type = "Value Flow"
        if not self.severity:
            self.severity = Severity.MEDIUM


@dataclass
class CallbackReentrancyFinding(Finding):
    """Reentrancy via token-transfer callback hooks (ERC777 / ERC721 / ERC1155 /
    ERC223) or callback-handler functions making untrusted calls."""
    def __post_init__(self):
        self.type = "Callback Reentrancy"
        if not self.severity:
            self.severity = Severity.HIGH


@dataclass
class IntegerTruncationFinding(Finding):
    """Precision-loss / rounding-down from divide-before-multiply in value math."""
    def __post_init__(self):
        self.type = "Integer Truncation"
        if not self.severity:
            self.severity = Severity.MEDIUM


@dataclass
class OracleTaintFinding(Finding):
    """Oracle read (Chainlink / AMM TWAP) flowing into value movement without
    manipulation or staleness validation."""
    def __post_init__(self):
        self.type = "Oracle Taint"
        if not self.severity:
            self.severity = Severity.HIGH


class FindingCollector:
    """Collection of findings with generator support and magic methods."""
    
    def __init__(self):
        self._findings: List[Finding] = []
        self._console = Console()
    
    def add(self, finding: Finding) -> None:
        """Add a finding to the collection."""
        self._findings.append(finding)
    
    def extend(self, findings: List[Finding]) -> None:
        """Add multiple findings to the collection."""
        self._findings.extend(findings)
    
    def __len__(self) -> int:
        """Return the number of findings."""
        return len(self._findings)
    
    def __getitem__(self, index: int) -> Finding:
        """Get a finding by index."""
        return self._findings[index]
    
    def __iter__(self) -> Iterator[Finding]:
        """Iterate over findings."""
        return iter(self._findings)
    
    def __contains__(self, finding: Finding) -> bool:
        """Check if a finding is in the collection."""
        return finding in self._findings
    
    def filter_by_severity(self, severity: Severity) -> Iterator[Finding]:
        """Generator that yields findings of a specific severity."""
        yield from (f for f in self._findings if f.severity == severity)
    
    def filter_by_type(self, finding_type: str) -> Iterator[Finding]:
        """Generator that yields findings of a specific type."""
        yield from (f for f in self._findings if f.type == finding_type)
    
    def filter_by_file(self, file_path: str) -> Iterator[Finding]:
        """Generator that yields findings from a specific file."""
        yield from (f for f in self._findings if f.file_path == file_path)
    
    def get_summary(self) -> Dict[str, int]:
        """Get summary statistics of findings."""
        summary = {}
        for finding in self._findings:
            key = f"{finding.type} ({finding.severity.value})"
            summary[key] = summary.get(key, 0) + 1
        return summary
    
    def render(self):
        """Return a Rich Table object for pretty printing."""
        if not self._findings:
            from rich.text import Text
            return Text("✅ No issues detected!", style="green")
        
        table = Table(title=f"Found {len(self._findings)} Issues")
        table.add_column("Type", style="cyan")
        table.add_column("Severity", style="magenta")
        table.add_column("Message", style="white")
        table.add_column("Line", style="yellow")
        table.add_column("File", style="dim")
        
        for finding in self._findings:
            line_str = str(finding.line_number) if finding.line_number else "N/A"
            if finding.file_path:
                file_str = os.path.basename(finding.file_path)
            else:
                file_str = "N/A"
            table.add_row(
                finding.type,
                finding.severity.value,
                finding.message,
                line_str,
                file_str
            )
        return table

    def __str__(self) -> str:
        """Simple summary string for the collection."""
        if not self._findings:
            return "✅ No issues detected!"
        return f"Found {len(self._findings)} issues. Use .render() for details."
    
    def __repr__(self) -> str:
        """Detailed representation for debugging."""
        return f"FindingCollector({len(self._findings)} findings)"
    
    def to_dict(self) -> List[Dict[str, Any]]:
        """Convert findings to dictionary format."""
        return [
            {
                "type": f.type,
                "message": f.message,
                "severity": f.severity.value,
                "line_number": f.line_number,
                "file_path": f.file_path,
                "source_code": f.source_code,
                "context": f.context
            }
            for f in self._findings
        ]
    
    def clear(self) -> None:
        """Clear all findings."""
        self._findings.clear()
    
    def sort_by_severity(self) -> None:
        """Sort findings by severity (CRITICAL first)."""
        severity_order = {Severity.CRITICAL: 0, Severity.HIGH: 1, Severity.MEDIUM: 2, Severity.LOW: 3}
        self._findings.sort(key=lambda f: severity_order[f.severity])
    
    def sort_by_line(self) -> None:
        """Sort findings by line number."""
        self._findings.sort(key=lambda f: f.line_number or 0)
