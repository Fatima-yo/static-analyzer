"""
Core Analyzer for the Solidity Static Analyzer.

This module provides the main Analyzer class with generator-based AST walking,
detector registration, and super-pythonic features.
"""

import os
from typing import Dict, Any, Iterator, List, Optional, Generator
from pathlib import Path
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn

from .findings import FindingCollector, Finding, Severity
from .utils import (
    generate_ast, walk_ast_generator, find_sol_files_generator,
    get_solidity_version, DETECTOR_REGISTRY, DETECTOR_INFO, UncheckedContext,
    timing_context, error_context, with_progress
)
from .plugins import load_all_plugins
from .context import AnalyzerContext, set_analysis_context


class Analyzer:
    """
    Main analyzer class with generator-based AST walking and detector execution.
    
    This class provides a super-pythonic interface for analyzing Solidity contracts
    with memory-efficient generators, decorator-based detector registration,
    and beautiful output through magic methods.
    """
    
    def __init__(self, categories: Optional[List[str]] = None):
        # Ensure all detectors are registered
        import smart_analyzer.detectors
        self.console = Console()
        self._detectors = DETECTOR_REGISTRY.copy()
        self._unchecked_context = UncheckedContext()
        
        # Filter detectors by category if specified
        if categories:
            self._detectors = {
                name: func for name, func in self._detectors.items()
                if name in DETECTOR_INFO and DETECTOR_INFO[name].category in categories
            }
            self.console.print(f"[dim]Filtered to categories: {', '.join(categories)}[/dim]")
        
        # Load plugins automatically
        self._load_plugins()
    
    def _load_plugins(self) -> None:
        """Load all available plugins."""
        try:
            loaded_plugins = load_all_plugins()
            if loaded_plugins:
                self.console.print(f"[dim]Loaded {len(loaded_plugins)} plugins: {', '.join(loaded_plugins)}[/dim]")
        except Exception as e:
            self.console.print(f"[yellow]Warning: Failed to load plugins: {e}[/yellow]")
    
    def reload_plugins(self) -> None:
        """Reload all plugins."""
        self._load_plugins()
        self._detectors = DETECTOR_REGISTRY.copy()
    
    def get_loaded_plugins(self) -> List[str]:
        """Get list of loaded plugin names."""
        return [name for name in self._detectors.keys() if name not in [
            "reentrancy", "unchecked_call", "signature_replay", "signature_in_loop", 
            "tx_origin", "integer_overflow", "oracle_manipulation"
        ]]
    
    def __len__(self) -> int:
        """Return the number of registered detectors."""
        return len(self._detectors)
    
    def __contains__(self, detector_name: str) -> bool:
        """Check if a detector is registered."""
        return detector_name in self._detectors
    
    def __getitem__(self, detector_name: str):
        """Get a detector by name."""
        return self._detectors[detector_name]
    
    def __iter__(self) -> Iterator[str]:
        """Iterate over detector names."""
        return iter(self._detectors.keys())
    
    def register_detector(self, name: str, detector_func) -> None:
        """Register a new detector."""
        self._detectors[name] = detector_func
    
    def unregister_detector(self, name: str) -> None:
        """Unregister a detector."""
        if name in self._detectors:
            del self._detectors[name]
    
    def get_detector_names(self) -> List[str]:
        """Get list of registered detector display names."""
        return [DETECTOR_INFO[name].display_name for name in self._detectors.keys()]
    
    def get_detector_info(self) -> Dict[str, 'DetectorInfo']:
        """Get detector info dictionary."""
        return {name: DETECTOR_INFO[name] for name in self._detectors.keys()}
    
    def get_available_categories(self) -> List[str]:
        """Get list of available detector categories."""
        categories = set()
        for name in DETECTOR_INFO:
            categories.add(DETECTOR_INFO[name].category)
        return sorted(list(categories))
    
    def get_detectors_by_category(self, category: str) -> Dict[str, 'DetectorInfo']:
        """Get detectors filtered by category."""
        return {
            name: DETECTOR_INFO[name] for name in DETECTOR_INFO
            if DETECTOR_INFO[name].category == category
        }
    
    def get_category_summary(self) -> Dict[str, int]:
        """Get summary of detectors by category."""
        summary = {}
        for name in DETECTOR_INFO:
            category = DETECTOR_INFO[name].category
            summary[category] = summary.get(category, 0) + 1
        return summary
    
    def analyze_contract_generator(self, sol_file: str, project_root: Optional[str] = None) -> Generator[Finding, None, None]:
        """
        Generator that yields findings as they're discovered.
        
        Args:
            sol_file: Path to the Solidity file
            project_root: Optional project root for multi-file analysis
        
        Yields:
            Finding objects as they're detected
        """
        with error_context(f"analyzing {sol_file}"):
            # Generate AST
            ast_data = generate_ast(sol_file, project_root)
            
            # Get the correct AST root
            if project_root:
                relative_path = os.path.relpath(sol_file, project_root)
                if relative_path in ast_data["sources"]:
                    ast_root = ast_data["sources"][relative_path]["ast"]
                else:
                    raise Exception(f"Could not find AST for {relative_path}")
            else:
                ast_root = ast_data["sources"]["input.sol"]["ast"]
            
            # Get Solidity version
            version = get_solidity_version(sol_file)
            
            # Reset unchecked context
            self._unchecked_context = UncheckedContext()
            
            # Build project-wide context so detectors can reason about contracts,
            # inheritance and cross-references instead of raw node patterns.
            context = AnalyzerContext(ast_data)
            set_analysis_context(context)
            # Node ids collide across compilations; never reuse cross-file caches.
            from .context import _reentry_call_cache
            _reentry_call_cache.clear()
            
            # Walk AST and run detectors
            for node in walk_ast_generator(ast_root):
                # Update unchecked context
                self._unchecked_context.enter(node)
                
                # Run all detectors on this node
                for detector_name, detector_func in self._detectors.items():
                    try:
                        # Create temporary findings list
                        temp_findings = []
                        
                        # Call detector with appropriate arguments
                        if detector_name == "integer_overflow":
                            detector_func(node, temp_findings, sol_file, version, self._unchecked_context)
                        else:
                            detector_func(node, temp_findings, sol_file)
                        
                        # Yield findings
                        for finding in temp_findings:
                            yield finding
                    
                    except Exception as e:
                        self.console.print(f"[yellow]Warning: Detector {detector_name} failed: {e}[/yellow]")
                
                # Update unchecked context after processing
                self._unchecked_context.exit(node)
            
            # Clear project context for this file
            set_analysis_context(None)
    
    def analyze_contracts_generator(self, folder_path: str) -> Generator[Finding, None, None]:
        """
        Generator that yields findings from all contracts in a folder.
        
        Args:
            folder_path: Path to folder containing .sol files
        
        Yields:
            Finding objects from all contracts
        """
        sol_files = list(find_sol_files_generator(folder_path))
        
        if not sol_files:
            # Clean up message for temporary paths
            if "/tmp" in folder_path or "/var/folders" in folder_path:
                self.console.print(f"[yellow]No .sol files found in test directory[/yellow]")
            else:
                self.console.print(f"[yellow]No .sol files found in {folder_path}[/yellow]")
            return
        
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=self.console
        ) as progress:
            task = progress.add_task("Analyzing contracts", total=len(sol_files))
            
            for i, sol_file in enumerate(sol_files, 1):
                file_name = os.path.basename(sol_file)
                progress.update(task, description=f"Analyzing {file_name} ({i}/{len(sol_files)})")
                
                try:
                    # Yield findings from this contract
                    for finding in self.analyze_contract_generator(sol_file, folder_path):
                        yield finding
                except Exception as e:
                    # Clean up error message for temporary paths
                    if "/tmp" in sol_file or "/var/folders" in sol_file:
                        error_file = os.path.basename(sol_file)
                    else:
                        error_file = sol_file
                    self.console.print(f"[red]Error analyzing {error_file}: {e}[/red]")
                
                progress.advance(task)
    
    def analyze_contract(self, sol_file: str, project_root: Optional[str] = None) -> FindingCollector:
        """
        Analyze a single contract and return findings.
        
        Args:
            sol_file: Path to the Solidity file
            project_root: Optional project root for multi-file analysis
        
        Returns:
            FindingCollector with all findings
        """
        collector = FindingCollector()
        
        with timing_context(f"Analyzing {os.path.basename(sol_file)}"):
            for finding in self.analyze_contract_generator(sol_file, project_root):
                collector.add(finding)
        
        return collector
    
    def analyze_contracts(self, folder_path: str) -> FindingCollector:
        """
        Analyze all contracts in a folder and return findings.
        
        Args:
            folder_path: Path to folder containing .sol files
        
        Returns:
            FindingCollector with all findings
        """
        collector = FindingCollector()
        
        with timing_context(f"Analyzing contracts in {folder_path}"):
            for finding in self.analyze_contracts_generator(folder_path):
                collector.add(finding)
        
        return collector
    
    def analyze_with_summary(self, folder_path: str) -> Dict[str, Any]:
        """
        Analyze contracts and return detailed summary.
        
        Args:
            folder_path: Path to folder containing .sol files
        
        Returns:
            Dictionary with analysis results and summary
        """
        collector = self.analyze_contracts(folder_path)
        
        # Get summary statistics
        summary = collector.get_summary()
        
        # Group findings by file
        findings_by_file = {}
        for finding in collector:
            file_name = os.path.basename(finding.file_path) if finding.file_path else "Unknown"
            if file_name not in findings_by_file:
                findings_by_file[file_name] = []
            findings_by_file[file_name].append(finding)
        
        return {
            "total_findings": len(collector),
            "summary": summary,
            "findings_by_file": findings_by_file,
            "collector": collector
        }
    
    def __str__(self) -> str:
        """String representation of the analyzer."""
        detector_list = ", ".join(self.get_detector_names())
        return f"Analyzer with {len(self)} detectors: {detector_list}"
    
    def __repr__(self) -> str:
        """Detailed representation for debugging."""
        return f"Analyzer(detectors={list(self._detectors.keys())})"
    
    def get_stats(self) -> Dict[str, Any]:
        """Get analyzer statistics."""
        return {
            "detector_count": len(self._detectors),
            "detector_names": self.get_detector_names(),
            "unchecked_context_depth": self._unchecked_context.unchecked_depth
        }
