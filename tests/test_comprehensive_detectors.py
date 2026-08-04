"""
Comprehensive test suite for all vulnerability detectors.

This module tests all detectors with real contract examples and
ensures they correctly identify vulnerabilities.
"""

import pytest
import tempfile
import os
from pathlib import Path
from smart_analyzer.analyzer import Analyzer
from smart_analyzer.findings import Severity


class TestComprehensiveDetectors:
    """Test suite for comprehensive vulnerability detection."""
    
    @pytest.fixture
    def analyzer(self):
        """Create analyzer instance."""
        return Analyzer()
    
    @pytest.fixture
    def temp_dir(self):
        """Create temporary directory for test contracts."""
        with tempfile.TemporaryDirectory() as temp_dir:
            yield temp_dir
    
    def test_access_control_detection(self, analyzer, temp_dir):
        """Test access control vulnerability detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract AccessControlVulnerable {
            address public owner;
            uint256 public balance;
            
            constructor() {
                owner = msg.sender;
            }
            
            // VULNERABLE: Missing access control (privileged setter, no guard)
            function setBalance(uint256 newBalance) public {
                balance = newBalance;
            }
            
            // VULNERABLE: Using tx.origin for authorization
            function adminOnly() public {
                require(tx.origin == owner, "Not authorized");
            }
        }
        """
        
        contract_path = Path(temp_dir) / "AccessControlVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        # Should detect access control issues
        access_control_findings = [f for f in findings if "access_control" in str(f).lower()]
        tx_origin_findings = [f for f in findings if "tx.origin" in str(f).lower()]
        
        assert len(access_control_findings) > 0, "Should detect access control vulnerabilities"
        assert len(tx_origin_findings) > 0, "Should detect tx.origin usage"
    
    def test_flash_loan_detection(self, analyzer, temp_dir):
        """Test flash loan vulnerability detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract FlashLoanVulnerable {
            uint256 public totalSupply;
            mapping(address => uint256) public balanceOf;
            
            // VULNERABLE: Flash loan without proper validation
            function flashLoan(uint256 amount) external {
                balanceOf[msg.sender] += amount;
                // No validation of returned amount
            }
        }
        """
        
        contract_path = Path(temp_dir) / "FlashLoanVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        flash_loan_findings = [f for f in findings if "flash" in str(f).lower()]
        assert len(flash_loan_findings) > 0, "Should detect flash loan vulnerabilities"
    
    def test_front_running_detection(self, analyzer, temp_dir):
        """Test front-running vulnerability detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract FrontRunningVulnerable {
            uint256 public price;
            
            // VULNERABLE: Front-running in mint function
            function mint() public payable {
                require(msg.value >= price, "Insufficient payment");
                // No slippage protection
            }
            
            // VULNERABLE: Front-running in swap function
            function swap(uint256 amountIn) public returns (uint256 amountOut) {
                amountOut = (amountIn * price) / 1e18;
                // No deadline or slippage protection
            }
        }
        """
        
        contract_path = Path(temp_dir) / "FrontRunningVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        front_running_findings = [f for f in findings if "front" in str(f).lower()]
        assert len(front_running_findings) > 0, "Should detect front-running vulnerabilities"
    
    def test_timestamp_detection(self, analyzer, temp_dir):
        """Test timestamp dependence detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract TimestampVulnerable {
            uint256 public randomNumber;
            
            // VULNERABLE: Using block.timestamp for randomness
            function generateRandom() public {
                randomNumber = uint256(keccak256(abi.encodePacked(block.timestamp)));
            }
            
            // VULNERABLE: Using block.timestamp for time-based logic
            function canUpdate() public view returns (bool) {
                return block.timestamp == 1000;
            }
        }
        """
        
        contract_path = Path(temp_dir) / "TimestampVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        timestamp_findings = [f for f in findings if "timestamp" in str(f).lower()]
        assert len(timestamp_findings) > 0, "Should detect timestamp dependence"
    
    def test_gas_limit_detection(self, analyzer, temp_dir):
        """Test gas limit vulnerability detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract GasLimitVulnerable {
            uint256[] public items;
            
            // VULNERABLE: Unbounded loop
            function processAllItems() public {
                for (uint256 i = 0; i < items.length; i++) {
                    items[i] = items[i] * 2;
                }
            }
        }
        """
        
        contract_path = Path(temp_dir) / "GasLimitVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        gas_limit_findings = [f for f in findings if "gas" in str(f).lower()]
        assert len(gas_limit_findings) > 0, "Should detect gas limit issues"
    
    def test_delegate_call_detection(self, analyzer, temp_dir):
        """Test delegate call vulnerability detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract DelegateCallVulnerable {
            address public implementation;
            
            // VULNERABLE: Delegate call to arbitrary address
            function execute(bytes memory data) public {
                (bool success, ) = implementation.delegatecall(data);
                require(success, "Delegate call failed");
            }
        }
        """
        
        contract_path = Path(temp_dir) / "DelegateCallVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        delegate_call_findings = [f for f in findings if "delegate" in str(f).lower()]
        assert len(delegate_call_findings) > 0, "Should detect delegate call vulnerabilities"
    
    def test_events_detection(self, analyzer, temp_dir):
        """Test missing events detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract EventsVulnerable {
            uint256 public balance;
            
            // VULNERABLE: Missing event emission
            function transfer(address to, uint256 amount) public {
                balance -= amount;
                // Missing Transfer event
            }
            
            // VULNERABLE: Missing event emission
            function mint(address to, uint256 amount) public {
                balance += amount;
                // Missing Mint event
            }
        }
        """
        
        contract_path = Path(temp_dir) / "EventsVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        events_findings = [f for f in findings if "event" in str(f).lower()]
        assert len(events_findings) > 0, "Should detect missing events"
    
    def test_uninitialized_detection(self, analyzer, temp_dir):
        """Test uninitialized variable detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract UninitializedVulnerable {
            // VULNERABLE: Uninitialized storage variable, later read
            uint256 public uninitializedValue;
            
            // VULNERABLE: Uninitialized storage variable, later read
            address public uninitializedAddress;
            
            function read() public view returns (uint256, address) {
                return (uninitializedValue, uninitializedAddress);
            }
        }
        """
        
        contract_path = Path(temp_dir) / "UninitializedVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        uninitialized_findings = [f for f in findings if "uninitialized" in str(f).lower()]
        assert len(uninitialized_findings) > 0, "Should detect uninitialized variables"
    
    def test_zero_address_detection(self, analyzer, temp_dir):
        """Test zero address check detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract ZeroAddressVulnerable {
            address public owner;
            
            // VULNERABLE: Missing zero address check
            function setOwner(address newOwner) public {
                owner = newOwner; // No check for address(0)
            }
            
            // VULNERABLE: Missing zero address check
            function transfer(address to, uint256 amount) public {
                // No check for address(0)
            }
        }
        """
        
        contract_path = Path(temp_dir) / "ZeroAddressVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        zero_address_findings = [f for f in findings if "zero" in str(f).lower()]
        assert len(zero_address_findings) > 0, "Should detect missing zero address checks"
    
    def test_type_cast_detection(self, analyzer, temp_dir):
        """Test unsafe type casting detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract TypeCastVulnerable {
            uint256 public value;
            
            // VULNERABLE: Unsafe type casting
            function unsafeCast(uint256 input) public {
                uint8 smallValue = uint8(input); // Truncation possible
                value = smallValue;
            }
            
            // VULNERABLE: Unsafe type casting
            function unsafeCast16(uint256 input) public {
                uint16 smallValue = uint16(input); // Truncation possible
                value = smallValue;
            }
        }
        """
        
        contract_path = Path(temp_dir) / "TypeCastVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        type_cast_findings = [f for f in findings if "type" in str(f).lower()]
        assert len(type_cast_findings) > 0, "Should detect unsafe type casting"
    
    def test_modifier_detection(self, analyzer, temp_dir):
        """Test incorrect modifier usage detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract ModifierVulnerable {
            address public owner;
            
            modifier onlyOwner() {
                require(msg.sender == owner, "Not owner");
                _;
            }
            
            // VULNERABLE: Missing onlyOwner modifier
            function withdraw(uint256 amount) public {
                payable(msg.sender).transfer(amount);
            }
            
            // VULNERABLE: Missing onlyOwner modifier
            function destroy() public {
                selfdestruct(payable(msg.sender));
            }
        }
        """
        
        contract_path = Path(temp_dir) / "ModifierVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        modifier_findings = [f for f in findings if "modifier" in str(f).lower()]
        assert len(modifier_findings) > 0, "Should detect incorrect modifier usage"
    
    def test_redundant_code_detection(self, analyzer, temp_dir):
        """Test redundant code detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract RedundantCodeVulnerable {
            uint256 public value;
            
            // VULNERABLE: Empty function
            function emptyFunction() public {
                // This function does nothing
            }
            
            // VULNERABLE: Dead code
            function deadCode() public {
                if (false) {
                    value = 100; // This will never execute
                }
            }
        }
        """
        
        contract_path = Path(temp_dir) / "RedundantCodeVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        redundant_findings = [f for f in findings if "redundant" in str(f).lower()]
        assert len(redundant_findings) > 0, "Should detect redundant code"
    
    def test_error_message_detection(self, analyzer, temp_dir):
        """Test poor error message detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract ErrorMessageVulnerable {
            uint256 public balance;
            
            // VULNERABLE: Generic error message
            function withdraw(uint256 amount) public {
                require(balance >= amount, "");
            }
            
            // VULNERABLE: Generic error message
            function transfer(address to, uint256 amount) public {
                require(balance >= amount, "Error");
            }
        }
        """
        
        contract_path = Path(temp_dir) / "ErrorMessageVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        error_message_findings = [f for f in findings if "error" in str(f).lower()]
        assert len(error_message_findings) > 0, "Should detect poor error messages"
    
    def test_hardcoded_detection(self, analyzer, temp_dir):
        """Test hardcoded value detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract HardcodedVulnerable {
            // VULNERABLE: Hardcoded values
            uint256 public constant HARDCODED_VALUE = 1000000;
            
            // VULNERABLE: Hardcoded values in functions
            function processWithHardcodedValue() public {
                uint256 result = 5000000; // Hardcoded magic number
            }
        }
        """
        
        contract_path = Path(temp_dir) / "HardcodedVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        hardcoded_findings = [f for f in findings if "hardcoded" in str(f).lower()]
        assert len(hardcoded_findings) > 0, "Should detect hardcoded values"
    
    def test_documentation_detection(self, analyzer, temp_dir):
        """Test missing documentation detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract DocumentationVulnerable {
            uint256 public balance;
            
            // VULNERABLE: Missing NatSpec documentation
            function transfer(address to, uint256 amount) public {
                balance -= amount;
            }
            
            // VULNERABLE: Missing NatSpec documentation
            function mint(address to, uint256 amount) public {
                balance += amount;
            }
        }
        """
        
        contract_path = Path(temp_dir) / "DocumentationVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        documentation_findings = [f for f in findings if "documentation" in str(f).lower()]
        assert len(documentation_findings) > 0, "Should detect missing documentation"
    
    def test_naming_detection(self, analyzer, temp_dir):
        """Test poor naming convention detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract NamingVulnerable {
            uint256 public x;
            uint256 public y;
            
            // VULNERABLE: Unclear function name
            function func() public {
                // Function does something
            }
            
            // VULNERABLE: Unclear function name
            function test() public {
                // Function does something
            }
        }
        """
        
        contract_path = Path(temp_dir) / "NamingVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        naming_findings = [f for f in findings if "naming" in str(f).lower()]
        assert len(naming_findings) > 0, "Should detect poor naming conventions"
    
    def test_mev_detection(self, analyzer, temp_dir):
        """Test MEV vulnerability detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract MEVVulnerable {
            uint256 public price;
            
            // VULNERABLE: MEV in swap function
            function swap(uint256 amountIn) public returns (uint256 amountOut) {
                amountOut = (amountIn * price) / 1e18;
                // No protection against MEV
            }
            
            // VULNERABLE: MEV in mint function
            function mint() public payable {
                require(msg.value >= price, "Insufficient payment");
                // No protection against MEV
            }
        }
        """
        
        contract_path = Path(temp_dir) / "MEVVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        mev_findings = [f for f in findings if "mev" in str(f).lower()]
        assert len(mev_findings) > 0, "Should detect MEV vulnerabilities"
    
    def test_storage_collision_detection(self, analyzer, temp_dir):
        """Test storage collision detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract BaseA {
            uint256 public valueA;
            address public ownerA;
            
            function initialize() public {
                valueA = 1;
            }
        }
        
        contract BaseB {
            mapping(address => uint256) public balancesB;
        }
        
        contract StorageCollisionVulnerable is BaseA, BaseB {
            uint256 public combined;
        }
        """
        
        contract_path = Path(temp_dir) / "StorageCollisionVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        storage_collision_findings = [f for f in findings if "storage" in str(f).lower()]
        assert len(storage_collision_findings) > 0, "Should detect storage collision issues"
    
    def test_upgrade_detection(self, analyzer, temp_dir):
        """Test upgrade pattern detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract UpgradeVulnerable {
            address public implementation;
            
            // VULNERABLE: Upgrade function without access control
            function upgrade(address newImplementation) public {
                implementation = newImplementation;
            }
            
            // VULNERABLE: Upgrade function without validation
            function upgradeTo(address newImplementation) public {
                implementation = newImplementation;
            }
        }
        """
        
        contract_path = Path(temp_dir) / "UpgradeVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        upgrade_findings = [f for f in findings if "upgrade" in str(f).lower()]
        assert len(upgrade_findings) > 0, "Should detect upgrade pattern issues"
    
    def test_cross_chain_detection(self, analyzer, temp_dir):
        """Test cross-chain vulnerability detection."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract CrossChainVulnerable {
            // VULNERABLE: Cross-chain bridge function
            function bridge(uint256 amount) public {
                // Bridge logic without proper validation
            }
            
            // VULNERABLE: Cross-chain function
            function crossChainTransfer(uint256 amount) public {
                // Cross-chain transfer without validation
            }
        }
        """
        
        contract_path = Path(temp_dir) / "CrossChainVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        cross_chain_findings = [f for f in findings if "cross" in str(f).lower()]
        assert len(cross_chain_findings) > 0, "Should detect cross-chain vulnerabilities"
    
    def test_comprehensive_analysis(self, analyzer, temp_dir):
        """Test comprehensive analysis with multiple vulnerabilities."""
        contract_content = """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        
        contract ComprehensiveVulnerable {
            address public owner;
            uint256 public balance;
            
            constructor() {
                owner = msg.sender;
            }
            
            // Multiple vulnerabilities in one function
            function vulnerableFunction(address to, uint256 amount) public {
                // Missing access control
                // Missing zero address check
                // Missing event emission
                // Using tx.origin
                require(tx.origin == owner, "Not authorized");
                balance -= amount;
                payable(to).transfer(amount);
            }
            
            // VULNERABLE: Unprotected privileged setter
            function setBalance(uint256 x) public {
                balance = x;
            }
            
            // VULNERABLE: Address param stored into state without zero check
            address public feeRecipient;
            function setFeeRecipient(address recipient) public {
                feeRecipient = recipient;
            }
            
            // Timestamp dependence
            function timeBased() public {
                if (block.timestamp == 1000) {
                    // Do something
                }
            }
            
            // Unchecked external call
            function externalCall() public {
                (bool success, ) = msg.sender.call("");
                // Missing require(success)
            }
        }
        """
        
        contract_path = Path(temp_dir) / "ComprehensiveVulnerable.sol"
        contract_path.write_text(contract_content)
        
        findings = list(analyzer.analyze_contract(str(contract_path)))
        
        # Should detect multiple types of vulnerabilities
        assert len(findings) > 5, "Should detect multiple vulnerabilities in comprehensive test"
        
        # Check for specific vulnerability types
        vulnerability_types = [str(f).lower() for f in findings]
        
        assert any("access" in v for v in vulnerability_types), "Should detect access control"
        assert any("zero" in v for v in vulnerability_types), "Should detect zero address"
        assert any("event" in v for v in vulnerability_types), "Should detect missing events"
        assert any("tx.origin" in v for v in vulnerability_types), "Should detect tx.origin usage"
        assert any("timestamp" in v for v in vulnerability_types), "Should detect timestamp dependence"
        assert any("unchecked" in v for v in vulnerability_types), "Should detect unchecked calls" 