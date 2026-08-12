# 🐍 Solidity Static Analyzer

A modular, extensible, and pythonic static analyzer for Solidity smart contracts. Designed for creativity, efficiency, and beauty. Easy to use, easy to extend, and a showcase of advanced Python features and best practices.

Disclaimer: This content serves solely as a proof of concept showcasing past DeFi hacking incidents. It is strictly intended for educational purposes and should not be interpreted as encouraging or endorsing any form of illegal activities or actual hacking attempts. The provided information is for informational and learning purposes only, and any actions taken based on this content are solely the responsibility of the individual. The usage of this information should adhere to applicable laws, regulations, and ethical standards.

---

## 📋 Table of Contents

1. [Project Overview](#project-overview)
2. [Features](#features)
3. [Project Structure](#project-structure)
4. [Installation](#installation)
5. [Usage](#usage)
6. [Detectors & Categories](#detectors--categories)
7. [Extending the Analyzer](#extending-the-analyzer)
8. [Configuration](#configuration)
9. [Testing](#testing)
10. [Best Practices](#best-practices)
11. [Support](#support)

---

## 🚀 Project Overview

This tool analyzes Solidity smart contracts for security vulnerabilities, best practices, gas optimizations, and documentation issues. It is:
- **Modular**: Add new detectors or plugins easily.
- **Pythonic**: Uses generators, decorators, dataclasses, and context managers.
- **Extensible**: Plugin system for user-contributed detectors.
- **Beautiful**: Rich, colorful output and clear findings.

---

## ✨ Features

- **Security Analysis**: Detects reentrancy, access control, signature replay, unchecked calls, and more (20 detectors).
- **Best Practices**: Flags missing events, poor error messages, redundant code, etc. (5 detectors).
- **Gas Optimization**: Identifies unbounded loops and other inefficiencies (1 detector).
- **Documentation**: Checks for missing docs and poor naming (3 detectors).
- **Plugin System**: Add your own detectors or output formatters.
- **Rich Output**: Table, JSON, and custom formats.
- **Comprehensive Testing**: Pytest-based suite for all detectors.
- **Easy Extensibility**: Decorator-based registration, plugin discovery, and config management.

---

## 📦 Project Structure

```
smart_analyzer/
├── analyzer.py         # Main Analyzer class, AST walker, detector registration
├── findings.py         # Finding base class, subclasses, collector
├── detectors/          # Built-in vulnerability detectors
│   ├── reentrancy.py
│   ├── signature.py
│   └── ...
├── output.py           # Output formatting, summary, logging
├── plugins/            # User-contributed detectors
├── utils.py            # AST utilities, file helpers, decorators
├── config.py           # Configuration management
├── main.py             # CLI entrypoint
├── requirements.txt    # Python dependencies
└── README.md           # This file!
```

---

## 🛠️ Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/mcastiglione/olympix-test.git
   cd olympix-test
   ```
2. **Install dependencies**
   ```bash
   pip install -r requirements.txt
   ```
3. *(Optional)* Set up a virtual environment:
   ```bash
   python -m venv venv
   source venv/bin/activate
   ```

---

## 🚦 Usage

### Analyze Contracts (CLI)

```bash
python main.py analyze contracts/
```

#### Options
- `-o, --output PATH`               Output file for results
- `-f, --format [table|json|csv]`   Output format
- `-s, --severity [LOW|MEDIUM|HIGH|CRITICAL]`  Filter by severity
- `-c, --categories TEXT`           Detector categories to run (security, best_practices, gas_optimization, documentation)
- `-d, --detectors TEXT`            Specific detectors to run
- `-e, --exclude TEXT`              Detectors to exclude
- `--debug`                         Enable debug mode
- `-v, --verbose`                   Verbose output
- `--help`                          Show help message

#### Examples
```bash
python main.py analyze contracts/ --severity HIGH --format json
python main.py analyze contracts/ --categories security best_practices
python main.py analyze contracts/ --detectors reentrancy oracle_manipulation
```

### Python API Usage

```python
from smart_analyzer.analyzer import Analyzer
from smart_analyzer.findings import FindingCollector

analyzer = Analyzer()
collector = FindingCollector()

for finding in analyzer.analyze_contracts('contracts/'):
    collector.add(finding)

print(collector)  # Uses __str__ for beautiful output
```

---

## 🏷️ Detectors & Categories

### Security Detectors (20 detectors)
- Reentrancy
- Access Control
- Flash Loan
- Front Running
- Timestamp
- Delegate Call
- Uninitialized
- Zero Address
- MEV
- Storage Collision
- Upgrade
- Cross Chain
- tx.origin
- Integer Overflow
- Oracle Manipulation
- Signature Replay
- Unchecked Call
- Signature in Loop
- Oracle Signature Reuse
- Oracle Price Manipulation

### Best Practices Detectors (5 detectors)
- Events
- Type Cast
- Modifier
- Redundant Code
- Error Messages

### Gas Optimization Detectors (1 detector)
- Gas Limit

### Documentation Detectors (3 detectors)
- Hardcoded
- Documentation
- Naming

#### Run by Category
```bash
python main.py analyze contracts/ --categories security
python main.py analyze contracts/ --categories best_practices
```

#### List All Detectors
```bash
python main.py list-detectors
```

---

## 🧩 Extending the Analyzer

### Adding New Detectors

**Built-in:**
Create a new file in `detectors/`:
```python
from typing import Dict, Any, List
from ..utils import detector, parse_src
from ..findings import Finding, Severity
from dataclasses import dataclass

@dataclass
class MyVulnerabilityFinding(Finding):
    def __post_init__(self):
        self.type = "My Vulnerability"
        if not self.severity:
            self.severity = Severity.MEDIUM

@detector("my_vulnerability", "🔍 My Vulnerability", "Detects my custom vulnerability")
def detect_my_vulnerability(node: Dict[str, Any], findings: List, file_path: str = None) -> None:
    if node.get("nodeType") == "FunctionCall":
        expr = node.get("expression", {})
        if expr.get("nodeType") == "Identifier" and expr.get("name") == "dangerousFunction":
            line_num = parse_src(node.get("src"), file_path)
            findings.append(MyVulnerabilityFinding(
                message="Dangerous function call detected without proper checks.",
                severity=Severity.HIGH,
                line_number=line_num,
                file_path=file_path,
                source_code=node.get("src")
            ))
```

**Plugin:**
Create a file in `plugins/`:
```python
from smart_analyzer.utils import detector, parse_src
from smart_analyzer.findings import Finding, Severity
from dataclasses import dataclass

@dataclass
class CustomVulnerabilityFinding(Finding):
    def __post_init__(self):
        self.type = "Custom Vulnerability"
        if not self.severity:
            self.severity = Severity.CRITICAL

@detector("custom_vulnerability", "🚨 Custom", "Detects custom vulnerability patterns")
def detect_custom_vulnerability(node, findings, file_path=None):
    if node.get("nodeType") == "FunctionCall":
        expr = node.get("expression", {})
        if (expr.get("nodeType") == "MemberAccess" and expr.get("memberName") == "delegatecall"):
            line_num = parse_src(node.get("src"), file_path)
            findings.append(CustomVulnerabilityFinding(
                message="Unsafe delegatecall detected. Validate the target contract.",
                severity=Severity.CRITICAL,
                line_number=line_num,
                file_path=file_path,
                source_code=node.get("src")
            ))
```

### Creating Plugins
- Place your plugin in `plugins/`
- Use the `@detector` decorator
- Document your plugin with a docstring
- Import from `smart_analyzer`

### Custom Output Formatters
You can create custom output formatters by extending `OutputFormatter` in `output.py`.

### Configuration Management
Extend `AnalyzerConfig` in `config.py` for custom settings. See `analyzer_config.yaml` for examples.

---

## ⚙️ Configuration

Example `analyzer_config.yaml`:
```yaml
output_format: rich
show_progress: true
show_summary: true

# Custom plugin settings
my_plugin_enabled: true
my_plugin_threshold: 10
my_plugin_patterns:
  - "*.sol"
  - "contracts/**/*.sol"

enabled_detectors:
  - "my_vulnerability"
  - "custom_vulnerability"
disabled_detectors:
  - "tx_origin"
```

---

## 🧪 Testing

### Run Tests
```bash
# Run comprehensive test suite (recommended)
python main.py test-comprehensive

# Run specific test file with pytest
python -m pytest tests/test_comprehensive_detectors.py -v

# Run all tests with pytest
python -m pytest tests/ -v
```

### Add Your Own Tests
- Place test files in `tests/`
- Use `pytest` for new detectors/plugins
- Follow the existing test patterns in `test_comprehensive_detectors.py`

---

## 📋 Best Practices

- **Single Responsibility**: Each detector should focus on one vulnerability type
- **Clear Messages**: Provide actionable, specific error messages
- **Proper Severity**: Use appropriate severity levels (LOW, MEDIUM, HIGH, CRITICAL)
- **Line Numbers**: Always include accurate line numbers for findings
- **Efficient AST Walking**: Use generators for memory efficiency
- **Early Exit**: Return early when possible to avoid unnecessary processing
- **Graceful Degradation**: Handle parsing errors without crashing
- **Comprehensive Coverage**: Test all code paths in your detectors
- **Clear Docstrings**: Document all functions and classes
- **Examples**: Provide usage examples for complex detectors

---

## 📞 Support

- **Issues**: Report bugs and request features on GitHub
- **Discussions**: Join community discussions for help and ideas
- **Documentation**: See this README for all info
- **Examples**: Look at existing detectors and plugins for reference

---

**Happy coding! 🐍✨** 
