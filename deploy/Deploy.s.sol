// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import "../src/tokens/GovernanceToken.sol";
import "../src/tokens/OutcomeToken.sol";
import "../src/tokens/FeeVault.sol";
import "../src/oracles/OracleAdapter.sol";
import "../src/core/PredictionMarket.sol";
import "../src/factories/MarketFactory.sol";
import "../src/governance/PredictionGovernor.sol";
import "../src/governance/MarketTimelock.sol";
import "../src/tokens/MockUSDC.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        vm.startBroadcast(deployerKey);
        MockUSDC usdc = new MockUSDC(deployer);
        usdc.mint(deployer, 1_000_000e6);
        address collateral = address(usdc);
        console.log("MockUSDC:    ", collateral);

        GovernanceToken govImpl = new GovernanceToken();
        ERC1967Proxy govProxy = new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(GovernanceToken.initialize, (deployer, deployer))
        );
        GovernanceToken govToken = GovernanceToken(address(govProxy));

        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(0); 
        executors[0] = address(0); 

        MarketTimelock timelock = new MarketTimelock(proposers, executors, deployer);

        PredictionGovernor governor = new PredictionGovernor(
            IVotes(address(govToken)),
            TimelockController(payable(address(timelock)))
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        OutcomeToken outcomeToken = new OutcomeToken(deployer);

        FeeVault feeVault = new FeeVault(IERC20(collateral), deployer);

        OracleAdapter oracle = new OracleAdapter();

        PredictionMarket marketImpl = new PredictionMarket();
        ERC1967Proxy marketProxy = new ERC1967Proxy(
            address(marketImpl),
            abi.encodeCall(PredictionMarket.initialize, (
    deployer,  
    collateral,
    address(outcomeToken),
    address(feeVault),
    address(oracle)
))
        );
        PredictionMarket market = PredictionMarket(address(marketProxy));

        outcomeToken.grantRole(outcomeToken.MINTER_ROLE(), address(market));
        feeVault.setMarket(address(market));

        MarketFactory factory = new MarketFactory(address(marketImpl), address(timelock));

        vm.stopBroadcast();

        console.log("=== DEPLOYED ADDRESSES ===");
        console.log("GovToken:    ", address(govToken));
        console.log("Timelock:    ", address(timelock));
        console.log("Governor:    ", address(governor));
        console.log("OutcomeToken:", address(outcomeToken));
        console.log("FeeVault:    ", address(feeVault));
        console.log("Oracle:      ", address(oracle));
        console.log("Market:      ", address(market));
        console.log("Factory:     ", address(factory));
    }
}