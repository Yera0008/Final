// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IPredictionMarket {
    function initialize(
        address admin,
        address collateral,
        address outcomeToken,
        address feeVault,
        address oracle  
    ) external;
}

contract MarketFactory is Ownable {
    address public implementation; 

    address[] public deployedMarkets;
    mapping(bytes32 => address) public saltToMarket;

    event MarketDeployed(address indexed market, bool indexed wasCREATE2, bytes32 salt);

    constructor(address impl, address owner_) Ownable(owner_) {
        implementation = impl;
    }

    function setImplementation(address newImpl) external onlyOwner {
        implementation = newImpl;
    }

    function deployMarket(
        address admin,
        address collateral,
        address outcomeToken,
        address feeVault,
        address oracle
    ) external onlyOwner returns (address market) {
        bytes memory initData = abi.encodeCall(
            IPredictionMarket.initialize,
            (admin, collateral, outcomeToken, feeVault, oracle)
        );

        // CREATE 
        ERC1967Proxy proxy = new ERC1967Proxy(implementation, initData);
        market = address(proxy);

        deployedMarkets.push(market);
        emit MarketDeployed(market, false, bytes32(0));
    }

    // CREATE2
    function deployMarketDeterministic(
        address admin,
        address collateral,
        address outcomeToken,
        address feeVault,
        address oracle,
        bytes32 salt
    ) external onlyOwner returns (address market) {
        require(saltToMarket[salt] == address(0), "Salt used");

        bytes memory initData = abi.encodeCall(
            IPredictionMarket.initialize,
            (admin, collateral, outcomeToken, feeVault, oracle)
        );

        bytes memory bytecode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(implementation, initData)
        );

        assembly {
            market := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(extcodesize(market)) { revert(0, 0) }
        }

        saltToMarket[salt] = market;
        deployedMarkets.push(market);
        emit MarketDeployed(market, true, salt);
    }

    function predictAddress(
        bytes32 salt,
        address collateral,
        address outcomeToken,
        address feeVault,
        address oracle,
        address admin
    ) external view returns (address) {
        bytes memory initData = abi.encodeCall(
            IPredictionMarket.initialize,
            (admin, collateral, outcomeToken, feeVault, oracle)
        );
        bytes32 bytecodeHash = keccak256(abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(implementation, initData)
        ));
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(this), salt, bytecodeHash
        )))));
    }

    function getDeployedMarkets() external view returns (address[] memory) {
        return deployedMarkets;
    }
}