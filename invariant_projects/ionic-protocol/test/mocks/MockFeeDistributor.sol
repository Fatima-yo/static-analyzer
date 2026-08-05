// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import { IFeeDistributor } from "../../src/compound/IFeeDistributor.sol";
import { CErc20Delegator } from "../../src/compound/CErc20Delegator.sol";
import { IonicComptroller } from "../../src/compound/ComptrollerInterface.sol";
import { InterestRateModel } from "../../src/compound/InterestRateModel.sol";
import { AuthoritiesRegistry } from "../../src/ionic/AuthoritiesRegistry.sol";

/// @notice Minimal FeeDistributor (the Ionic admin) for the harness. It acts
/// as `ionicAdmin` for every CErc20Delegator (the delegator constructor
/// requires `msg.sender == ionicAdmin`), authorizes every action via a
/// permissive `canCall`, and serves the CErc20Delegate + CTokenFirstExtension
/// extension addresses that the delegator's `_setImplementationSafe` needs.
contract MockFeeDistributor is IFeeDistributor {
    address public immutable cErc20Delegate;
    address public immutable cTokenFirstExtension;
    address[] public extensions;
    address[] public markets;

    constructor(address cErc20Delegate_, address cTokenFirstExtension_) {
        cErc20Delegate = cErc20Delegate_;
        cTokenFirstExtension = cTokenFirstExtension_;
        extensions = new address[](2);
        extensions[0] = cErc20Delegate_;
        extensions[1] = cTokenFirstExtension_;
    }

    function deployMarket(
        address underlying,
        IonicComptroller comptroller,
        InterestRateModel interestRateModel,
        string memory name,
        string memory symbol,
        uint256 reserveFactorMantissa,
        uint256 adminFeeMantissa
    ) public returns (address) {
        CErc20Delegator d = new CErc20Delegator(
            underlying,
            comptroller,
            payable(address(this)),
            interestRateModel,
            name,
            symbol,
            reserveFactorMantissa,
            adminFeeMantissa
        );
        markets.push(address(d));
        return address(d);
    }

    function minBorrowEth() external pure returns (uint256) {
        return 0;
    }

    function maxUtilizationRate() external pure returns (uint256) {
        return 1e18;
    }

    function interestFeeRate() external pure returns (uint256) {
        return 0.005e18;
    }

    function latestComptrollerImplementation(address) external pure returns (address) {
        return address(0);
    }

    function latestCErc20Delegate(uint8) external view returns (address, bytes memory) {
        return (cErc20Delegate, "");
    }

    function latestPluginImplementation(address) external pure returns (address) {
        return address(0);
    }

    function getComptrollerExtensions(address) external pure returns (address[] memory) {
        return new address[](0);
    }

    function getCErc20DelegateExtensions(address) external view returns (address[] memory) {
        return extensions;
    }

    function deployCErc20(
        uint8,
        bytes calldata constructorData,
        bytes calldata becomeImplData
    ) external returns (address) {
        (
            address underlying,
            IonicComptroller comptroller,
            InterestRateModel interestRateModel,
            string memory name,
            string memory symbol,
            uint256 reserveFactorMantissa,
            uint256 adminFeeMantissa
        ) = abi.decode(
            constructorData,
            (address, IonicComptroller, InterestRateModel, string, string, uint256, uint256)
        );
        return
            deployMarket(
                underlying,
                comptroller,
                interestRateModel,
                name,
                symbol,
                reserveFactorMantissa,
                adminFeeMantissa
            );
    }

    function canCall(address, address, address, bytes4) external pure returns (bool) {
        return true;
    }

    function authoritiesRegistry() external pure returns (AuthoritiesRegistry) {
        return AuthoritiesRegistry(address(0));
    }

    fallback() external payable {}

    receive() external payable {}
}
