// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.7.6;

import "../src/contract/interface/RocketStorageInterface.sol";

/// @notice In-memory Rocket Pool storage. The real RocketStorage contract is a
/// generic key/value store; we model exactly the keys RocketTokenRETH touches:
///   - "contract.address" + name  -> deployed network contract address
///   - keccak("dao.protocol.setting.network") + "network.reth.deposit.delay"
///   - "user.deposit.block" + user -> deposit block (set by the deposit pool)
/// plus everything else the interface requires so the vendored contract links.
contract MockStorage is RocketStorageInterface {
    mapping(bytes32 => address) internal _addresses;
    mapping(bytes32 => uint256) internal _uints;
    mapping(bytes32 => string) internal _strings;
    mapping(bytes32 => bytes) internal _bytes;
    mapping(bytes32 => bool) internal _bools;
    mapping(bytes32 => int256) internal _ints;
    mapping(bytes32 => bytes32) internal _bytes32s;

    bool internal deployedStatus;

    address internal guardian;

    constructor(
        address _rocketDepositPool,
        address _rocketNetworkBalances,
        address _rocketDAOProtocolSettingsNetwork,
        uint256 _rethDepositDelay
    ) {
        _setContractAddress("rocketDepositPool", _rocketDepositPool);
        _setContractAddress("rocketNetworkBalances", _rocketNetworkBalances);
        _setContractAddress("rocketDAOProtocolSettingsNetwork", _rocketDAOProtocolSettingsNetwork);
        _uints[_depositDelayKey()] = _rethDepositDelay;
    }

    function _depositDelayKey() internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256("dao.protocol.setting.network"), "network.reth.deposit.delay"));
    }

    function _setContractAddress(string memory _name, address _addr) internal {
        _addresses[keccak256(abi.encodePacked("contract.address", _name))] = _addr;
    }

    function setContractAddress(string calldata _name, address _addr) external {
        _setContractAddress(_name, _addr);
    }

    function setUserDepositBlock(address _user, uint256 _block) external {
        _uints[keccak256(abi.encodePacked("user.deposit.block", _user))] = _block;
    }

    function getUserDepositBlock(address _user) external view returns (uint256) {
        return _uints[keccak256(abi.encodePacked("user.deposit.block", _user))];
    }

    function getAddress(bytes32 _key) external view override returns (address) {
        return _addresses[_key];
    }

    function getUint(bytes32 _key) external view override returns (uint) {
        return _uints[_key];
    }

    function getString(bytes32 _key) external view override returns (string memory) {
        return _strings[_key];
    }

    function getBytes(bytes32 _key) external view override returns (bytes memory) {
        return _bytes[_key];
    }

    function getBool(bytes32 _key) external view override returns (bool) {
        return _bools[_key];
    }

    function getInt(bytes32 _key) external view override returns (int) {
        return _ints[_key];
    }

    function getBytes32(bytes32 _key) external view override returns (bytes32) {
        return _bytes32s[_key];
    }

    function setAddress(bytes32 _key, address _value) external override {
        _addresses[_key] = _value;
    }

    function setUint(bytes32 _key, uint _value) external override {
        _uints[_key] = _value;
    }

    function setString(bytes32 _key, string calldata _value) external override {
        _strings[_key] = _value;
    }

    function setBytes(bytes32 _key, bytes calldata _value) external override {
        _bytes[_key] = _value;
    }

    function setBool(bytes32 _key, bool _value) external override {
        _bools[_key] = _value;
    }

    function setInt(bytes32 _key, int _value) external override {
        _ints[_key] = _value;
    }

    function setBytes32(bytes32 _key, bytes32 _value) external override {
        _bytes32s[_key] = _value;
    }

    function deleteAddress(bytes32 _key) external override {
        delete _addresses[_key];
    }

    function deleteUint(bytes32 _key) external override {
        delete _uints[_key];
    }

    function deleteString(bytes32 _key) external override {
        delete _strings[_key];
    }

    function deleteBytes(bytes32 _key) external override {
        delete _bytes[_key];
    }

    function deleteBool(bytes32 _key) external override {
        delete _bools[_key];
    }

    function deleteInt(bytes32 _key) external override {
        delete _ints[_key];
    }

    function deleteBytes32(bytes32 _key) external override {
        delete _bytes32s[_key];
    }

    function addUint(bytes32 _key, uint256 _amount) external override {
        _uints[_key] = _uints[_key] + _amount;
    }

    function subUint(bytes32 _key, uint256 _amount) external override {
        _uints[_key] = _uints[_key] - _amount;
    }

    function getDeployedStatus() external view override returns (bool) {
        return deployedStatus;
    }

    function getGuardian() external view override returns (address) {
        return guardian;
    }

    function setGuardian(address _newAddress) external override {
        guardian = _newAddress;
    }

    function confirmGuardian() external override {}

    function getNodeWithdrawalAddress(address _nodeAddress) external view override returns (address) {
        return address(0);
    }

    function getNodePendingWithdrawalAddress(address _nodeAddress) external view override returns (address) {
        return address(0);
    }

    function setWithdrawalAddress(address _nodeAddress, address _newWithdrawalAddress, bool _confirm) external override {}

    function confirmWithdrawalAddress(address _nodeAddress) external override {}
}
