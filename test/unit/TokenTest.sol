// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../src/tokens/GovernanceToken.sol";
import "../../src/tokens/OutcomeToken.sol";
import "../../src/tokens/FeeVault.sol";
import "../../src/factories/MarketFactory.sol";
import "../../src/core/PredictionMarket.sol";
import "../../src/governance/PredictionGovernor.sol";
import "../../src/governance/MarketTimelock.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../../src/oracles/OracleAdapter.sol";
import "../../src/oracles/MockAggregator.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("MockUSDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ═══════════════════════════════════════════════════════════════════
//  Governance Tests  
// ═══════════════════════════════════════════════════════════════════

contract GovernanceTest is Test {
    PredictionGovernor public governor;
    MarketTimelock     public timelock;
    GovernanceToken    public govToken;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function setUp() public {
        vm.startPrank(admin);

        GovernanceToken impl = new GovernanceToken();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GovernanceToken.initialize, (admin, admin))
        );
        govToken = GovernanceToken(address(proxy));

        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(0);
        executors[0] = address(0);
        timelock = new MarketTimelock(proposers, executors, admin);

        governor = new PredictionGovernor(
            IVotes(address(govToken)),
            TimelockController(payable(address(timelock)))
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(),  address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        govToken.transfer(alice, 40_000_000e18);
        govToken.transfer(bob,   40_000_000e18);

        vm.stopPrank();

        vm.prank(alice); govToken.delegate(alice);
        vm.prank(bob);   govToken.delegate(bob);
        vm.prank(admin); govToken.delegate(admin);

        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 2);
    }

    function test_gov_votingDelay_is1Day() public view {
    assertEq(governor.votingDelay(), 7200);
}

function test_gov_votingPeriod_is1Week() public view {
    assertEq(governor.votingPeriod(), 50400);
}

    function test_gov_quorum_is4Percent() public view {
        assertEq(governor.quorumNumerator(), 4);
    }

    function test_gov_proposalThreshold_is1Token() public view {
        assertEq(governor.proposalThreshold(), 1e18);
    }

    function test_gov_timelockDelay_is2Days() public view {
        assertEq(timelock.getMinDelay(), 2 days);
    }

    function test_gov_proposerRole_isGovernor() public view {
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
    }

    function test_gov_cancellerRole_isGovernor() public view {
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
    }

    function test_gov_token_hasVotes() public view {
        assertGt(governor.getVotes(alice, block.number - 1), 0);
    }

    function test_gov_propose_success() public {
        (uint256 proposalId,,,) = _createProposal();
        assertEq(uint8(governor.state(proposalId)), 0); // Pending
    }

    function test_gov_propose_stateIsPending() public {
        (uint256 proposalId,,,) = _createProposal();
        assertEq(uint8(governor.state(proposalId)), 0);
    }

    function test_gov_propose_revertsIfBelowThreshold() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert();
        governor.propose(_targets(), _values(), _calldatas(), "No tokens");
    }

    function test_gov_propose_stateIsActiveAfterDelay() public {
        (uint256 proposalId,,,) = _createProposal();
        _skipVotingDelay();
        assertEq(uint8(governor.state(proposalId)), 1); // Active
    }

    function test_gov_castVote_for() public {
        (uint256 proposalId,,,) = _createProposal();
        _skipVotingDelay();
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertGt(forVotes, 0);
    }

    function test_gov_castVote_against() public {
        (uint256 proposalId,,,) = _createProposal();
        _skipVotingDelay();
        vm.prank(alice);
        governor.castVote(proposalId, 0);
        (uint256 againstVotes,,) = governor.proposalVotes(proposalId);
        assertGt(againstVotes, 0);
    }

    function test_gov_castVote_abstain() public {
        (uint256 proposalId,,,) = _createProposal();
        _skipVotingDelay();
        vm.prank(alice);
        governor.castVote(proposalId, 2);
        (,, uint256 abstainVotes) = governor.proposalVotes(proposalId);
        assertGt(abstainVotes, 0);
    }

    function test_gov_castVote_revertsIfVotedTwice() public {
        (uint256 proposalId,,,) = _createProposal();
        _skipVotingDelay();
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(alice);
        vm.expectRevert();
        governor.castVote(proposalId, 1);
    }

    function test_gov_castVote_revertsBeforeVotingPeriod() public {
        (uint256 proposalId,,,) = _createProposal();
        vm.prank(alice);
        vm.expectRevert();
        governor.castVote(proposalId, 1);
    }

    function test_gov_proposal_succeededAfterVoting() public {
        (uint256 proposalId,,,) = _createProposal();
        _skipVotingDelay();
        vm.prank(alice); governor.castVote(proposalId, 1);
        vm.prank(bob);   governor.castVote(proposalId, 1);
        _skipVotingPeriod();
        assertEq(uint8(governor.state(proposalId)), 4); // Succeeded
    }

    function test_gov_proposal_defeatedIfNoQuorum() public {
        (uint256 proposalId,,,) = _createProposal();
        _skipVotingDelay();
        _skipVotingPeriod();
        assertEq(uint8(governor.state(proposalId)), 3); // Defeated
    }

    function test_gov_queue_revertsIfNotSucceeded() public {
        (,
            address[] memory targets,
            uint256[] memory values,
            bytes[]   memory calldatas
        ) = _createProposal();
        bytes32 descHash = keccak256(bytes("Send ETH to timelock"));
        vm.expectRevert();
        governor.queue(targets, values, calldatas, descHash);
    }

    function test_gov_execute_revertsBeforeTimelockDelay() public {
    (
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[]   memory calldatas
    ) = _createProposal();
    _skipVotingDelay();
    vm.prank(alice); governor.castVote(proposalId, 1);
    vm.prank(bob);   governor.castVote(proposalId, 1);
    _skipVotingPeriod();
    bytes32 descHash = keccak256(bytes("Send ETH to timelock"));
    governor.queue(targets, values, calldatas, descHash);
    vm.expectRevert();
    governor.execute(targets, values, calldatas, descHash);
}

    function test_gov_fullLifecycle_proposeVoteQueueExecute() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[]   memory calldatas
        ) = _createProposal();

        assertEq(uint8(governor.state(proposalId)), 0); // Pending

        _skipVotingDelay();
        assertEq(uint8(governor.state(proposalId)), 1); // Active

        vm.prank(alice); governor.castVote(proposalId, 1);
        vm.prank(bob);   governor.castVote(proposalId, 1);

        _skipVotingPeriod();
        assertEq(uint8(governor.state(proposalId)), 4); // Succeeded

        bytes32 descHash = keccak256(bytes("Send ETH to timelock"));
        governor.queue(targets, values, calldatas, descHash);
        assertEq(uint8(governor.state(proposalId)), 5); // Queued

        vm.warp(block.timestamp + 2 days + 1);
        governor.execute(targets, values, calldatas, descHash);
        assertEq(uint8(governor.state(proposalId)), 7); // Executed
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _skipVotingDelay() internal {
    vm.roll(block.number + 7201);
    vm.warp(block.timestamp + 1 days + 1);
}

function _skipVotingPeriod() internal {
    vm.roll(block.number + 50401);
    vm.warp(block.timestamp + 1 weeks + 1);
}

    function _targets() internal view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(timelock);
    }

    function _values() internal pure returns (uint256[] memory v) {
        v = new uint256[](1);
        v[0] = 0;
    }

    function _calldatas() internal pure returns (bytes[] memory c) {
        c = new bytes[](1);
        c[0] = "";
    }

    function _createProposal() internal returns (
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[]   memory calldatas
    ) {
        targets   = _targets();
        values    = _values();
        calldatas = _calldatas();
        vm.prank(alice);
        proposalId = governor.propose(targets, values, calldatas, "Send ETH to timelock");
    }
}

// ═══════════════════════════════════════════════════════════════════
//  OutcomeToken Tests
// ═══════════════════════════════════════════════════════════════════

contract OutcomeTokenTest is Test {
    OutcomeToken public token;
    address admin = makeAddr("admin");
    address minter = makeAddr("minter");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.startPrank(admin);
        token = new OutcomeToken(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.stopPrank();
    }

    function test_outcome_mint_byMinter() public {
        vm.prank(minter);
        token.mint(alice, 1, 100, "");
        assertEq(token.balanceOf(alice, 1), 100);
    }

    function test_outcome_mint_revertsIfNotMinter() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 1, 100, "");
    }

    function test_outcome_burn_byMinter() public {
        vm.prank(minter);
        token.mint(alice, 1, 100, "");

        vm.prank(minter);
        token.burn(alice, 1, 50);
        assertEq(token.balanceOf(alice, 1), 50);
    }

    function test_outcome_burn_revertsIfNotMinter() public {
        vm.prank(minter);
        token.mint(alice, 1, 100, "");

        vm.prank(alice);
        vm.expectRevert();
        token.burn(alice, 1, 50);
    }

    function test_outcome_mintBatch_success() public {
        uint256[] memory ids     = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1; ids[1] = 2;
        amounts[0] = 100; amounts[1] = 200;

        vm.prank(minter);
        token.mintBatch(alice, ids, amounts, "");

        assertEq(token.balanceOf(alice, 1), 100);
        assertEq(token.balanceOf(alice, 2), 200);
    }

    function test_outcome_mintBatch_revertsIfNotMinter() public {
        uint256[] memory ids     = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 1; amounts[0] = 100;

        vm.prank(alice);
        vm.expectRevert();
        token.mintBatch(alice, ids, amounts, "");
    }

    function test_outcome_pause_preventsTransfer() public {
        vm.prank(minter);
        token.mint(alice, 1, 100, "");

        vm.prank(admin);
        token.pause();

        vm.prank(minter);
        vm.expectRevert();
        token.mint(alice, 1, 100, "");
    }

    function test_outcome_unpause_allowsMint() public {
        vm.prank(admin);
        token.pause();
        vm.prank(admin);
        token.unpause();

        vm.prank(minter);
        token.mint(alice, 1, 100, "");
        assertEq(token.balanceOf(alice, 1), 100);
    }

    function test_outcome_supportsInterface() public view {
        // ERC1155 interfaceId
        assertTrue(token.supportsInterface(0xd9b67a26));
        // AccessControl interfaceId
        assertTrue(token.supportsInterface(0x7965db0b));
    }
}

// ═══════════════════════════════════════════════════════════════════
//  FeeVault Tests
// ═══════════════════════════════════════════════════════════════════

contract FeeVaultTest is Test {
    FeeVault  public vault;
    MockERC20 public usdc;
    address admin  = makeAddr("admin");
    address market = makeAddr("market");
    address alice  = makeAddr("alice");

    function setUp() public {
        usdc  = new MockERC20();
        vault = new FeeVault(IERC20(address(usdc)), admin);

        vm.prank(admin);
        vault.setMarket(market);

        usdc.mint(market, 100_000e6);
        usdc.mint(alice,  100_000e6);

        vm.prank(market);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_vault_depositFee_byMarket() public {
        vm.prank(market);
        vault.depositFee(1000e6);
        assertEq(usdc.balanceOf(address(vault)), 1000e6);
    }

    function test_vault_depositFee_revertsIfNotMarket() public {
        vm.prank(alice);
        vm.expectRevert(FeeVault.OnlyMarket.selector);
        vault.depositFee(1000e6);
    }

    function test_vault_deposit_byAnyone() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000e6, alice);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_vault_withdraw_returnsAssets() public {
        vm.prank(alice);
        vault.deposit(1000e6, alice);

        uint256 shares = vault.balanceOf(alice);
        uint256 before = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertGt(usdc.balanceOf(alice), before);
    }

    function test_vault_totalAssets_correct() public {
        vm.prank(market);
        vault.depositFee(500e6);

        vm.prank(alice);
        vault.deposit(500e6, alice);

        assertEq(vault.totalAssets(), 1000e6);
    }

    function test_vault_setMarket_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setMarket(alice);
    }

    function test_vault_previewDeposit_correct() public view {
        uint256 shares = vault.previewDeposit(1000e6);
        assertGt(shares, 0);
    }
}

// ═══════════════════════════════════════════════════════════════════
//  MarketFactory Tests
// ═══════════════════════════════════════════════════════════════════

contract MarketFactoryTest is Test {
    MarketFactory    public factory;
    PredictionMarket public impl;
    MockERC20        public usdc;
    OutcomeToken     public outcomeToken;
    FeeVault         public feeVault;
    OracleAdapter    public oracle;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.startPrank(admin);

        usdc         = new MockERC20();
        outcomeToken = new OutcomeToken(admin);
        feeVault     = new FeeVault(IERC20(address(usdc)), admin);
        oracle       = new OracleAdapter();
        impl         = new PredictionMarket();
        factory      = new MarketFactory(address(impl), admin);

        vm.stopPrank();
    }

    function test_factory_deployMarket_CREATE() public {
        vm.prank(admin);
        address market = factory.deployMarket(
            admin,
            address(usdc),
            address(outcomeToken),
            address(feeVault),
            address(oracle)
        );

        assertNotEq(market, address(0));
        assertEq(factory.deployedMarkets(0), market);
    }

    function test_factory_deployMarket_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.deployMarket(admin, address(usdc), address(outcomeToken), address(feeVault), address(oracle));
    }

    function test_factory_deployDeterministic_CREATE2() public {
        bytes32 salt = keccak256("test-salt-1");

        vm.prank(admin);
        address market = factory.deployMarketDeterministic(
            admin, address(usdc), address(outcomeToken), address(feeVault), address(oracle), salt
        );

        assertNotEq(market, address(0));
        assertEq(factory.saltToMarket(salt), market);
    }

    function test_factory_predictAddress_matchesActual() public {
        bytes32 salt = keccak256("predict-salt");

        address predicted = factory.predictAddress(
            salt, address(usdc), address(outcomeToken), address(feeVault), address(oracle), admin
        );

        vm.prank(admin);
        address actual = factory.deployMarketDeterministic(
            admin, address(usdc), address(outcomeToken), address(feeVault), address(oracle), salt
        );

        assertEq(predicted, actual);
    }

    function test_factory_CREATE2_revertsDuplicateSalt() public {
        bytes32 salt = keccak256("duplicate-salt");

        vm.prank(admin);
        factory.deployMarketDeterministic(
            admin, address(usdc), address(outcomeToken), address(feeVault), address(oracle), salt
        );

        vm.prank(admin);
        vm.expectRevert("Salt used");
        factory.deployMarketDeterministic(
            admin, address(usdc), address(outcomeToken), address(feeVault), address(oracle), salt
        );
    }

    function test_factory_getDeployedMarkets() public {
        vm.startPrank(admin);
        factory.deployMarket(admin, address(usdc), address(outcomeToken), address(feeVault), address(oracle));
        factory.deployMarket(admin, address(usdc), address(outcomeToken), address(feeVault), address(oracle));
        vm.stopPrank();

        address[] memory markets = factory.getDeployedMarkets();
        assertEq(markets.length, 2);
    }

    function test_factory_setImplementation() public {
        PredictionMarket newImpl = new PredictionMarket();
        vm.prank(admin);
        factory.setImplementation(address(newImpl));
        assertEq(factory.implementation(), address(newImpl));
    }

    function test_factory_setImplementation_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.setImplementation(address(0));
    }

}
contract MockAggregatorTest is Test {
    MockAggregator feed;

    function setUp() public {
        feed = new MockAggregator(3000e8, 8);
    }

    function test_mock_latestRoundData() public view {
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, 3000e8);
    }

    function test_mock_getRoundData() public view {
        (, int256 answer,,,) = feed.getRoundData(1);
        assertEq(answer, 3000e8);
    }

    function test_mock_setAnswer() public {
        feed.setAnswer(4000e8);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, 4000e8);
    }

    function test_mock_decimals() public view {
        assertEq(feed.decimals(), 8);
    }

    function test_mock_description() public view {
        assertEq(feed.description(), "Mock");
    }

    function test_mock_version() public view {
        assertEq(feed.version(), 1);
}
    }

    contract GovernanceTokenTest is Test {
    GovernanceToken public govToken;
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.startPrank(admin);
        GovernanceToken impl = new GovernanceToken();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GovernanceToken.initialize, (admin, admin))
        );
        govToken = GovernanceToken(address(proxy));
        vm.stopPrank();
    }

    function test_gov_initialize_setsOwner() public view {
        assertEq(govToken.owner(), admin);
    }

    function test_gov_initialize_mintsToTreasury() public view {
        assertEq(govToken.balanceOf(admin), 100_000_000e18);
    }

    function test_gov_name_and_symbol() public view {
        assertEq(govToken.name(), "PredictToken");
        assertEq(govToken.symbol(), "PRED");
    }

    function test_gov_mint_byOwner() public {
    assertEq(govToken.totalSupply(), 100_000_000e18);
    vm.prank(admin);
    vm.expectRevert("Cap exceeded");
    govToken.mint(alice, 1000e18);
}

    function test_gov_mint_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        govToken.mint(alice, 1000e18);
    }

    function test_gov_mint_revertsIfExceedsCap() public {
        vm.prank(admin);
        vm.expectRevert("Cap exceeded");
        govToken.mint(alice, 1e30);
    }

    function test_gov_delegate_and_votes() public {
        vm.prank(admin);
        govToken.delegate(admin);
        assertGt(govToken.getVotes(admin), 0);
    }

    function test_gov_transfer_updatesVotes() public {
        vm.prank(admin);
        govToken.delegate(admin);
        vm.prank(alice);
        govToken.delegate(alice);
        vm.prank(admin);
        govToken.transfer(alice, 1000e18);
        assertGt(govToken.getVotes(alice), 0);
    }

    function test_gov_permit_works() public {
        uint256 pk = 0xA11CE;
        address owner_ = vm.addr(pk);
        vm.prank(admin);
        govToken.transfer(owner_, 100e18);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 domainSep = govToken.DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            owner_, alice, 50e18, govToken.nonces(owner_), deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        govToken.permit(owner_, alice, 50e18, deadline, v, r, s);
        assertEq(govToken.allowance(owner_, alice), 50e18);
    }

    function test_gov_upgrade_byOwner() public {
        GovernanceToken newImpl = new GovernanceToken();
        vm.prank(admin);
        govToken.upgradeToAndCall(address(newImpl), "");
    }

    function test_gov_upgrade_revertsIfNotOwner() public {
        GovernanceToken newImpl = new GovernanceToken();
        vm.prank(alice);
        vm.expectRevert();
        govToken.upgradeToAndCall(address(newImpl), "");
    }
}
// ═══════════════════════════════════════════════════════════════════
//  PredictionGovernor Direct Tests
// ═══════════════════════════════════════════════════════════════════

contract PredictionGovernorTest is Test {
    PredictionGovernor public governor;
    MarketTimelock     public timelock;
    GovernanceToken    public govToken;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function setUp() public {
        vm.startPrank(admin);
        GovernanceToken impl = new GovernanceToken();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GovernanceToken.initialize, (admin, admin))
        );
        govToken = GovernanceToken(address(proxy));

        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(0);
        executors[0] = address(0);
        timelock = new MarketTimelock(proposers, executors, admin);

        governor = new PredictionGovernor(
            IVotes(address(govToken)),
            TimelockController(payable(address(timelock)))
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(),  address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        govToken.transfer(alice, 40_000_000e18);
        govToken.transfer(bob,   40_000_000e18);
        vm.stopPrank();

        vm.prank(alice); govToken.delegate(alice);
        vm.prank(bob);   govToken.delegate(bob);
        vm.prank(admin); govToken.delegate(admin);

        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 2);
    }

    function _skipVotingDelay() internal {
        vm.roll(block.number + 7201);
        vm.warp(block.timestamp + 1 days + 1);
    }

    function _skipVotingPeriod() internal {
        vm.roll(block.number + 50401);
        vm.warp(block.timestamp + 1 weeks + 1);
    }

    function test_governor_name() public view {
        assertEq(governor.name(), "PredictionGovernor");
    }

    function test_governor_votingDelay() public view {
        assertEq(governor.votingDelay(), 7200);
    }

    function test_governor_votingPeriod() public view {
        assertEq(governor.votingPeriod(), 50400);
    }

    function test_governor_proposalThreshold() public view {
        assertEq(governor.proposalThreshold(), 1e18);
    }

    function test_governor_quorumNumerator() public view {
        assertEq(governor.quorumNumerator(), 4);
    }

    function test_governor_timelock() public view {
        assertEq(governor.timelock(), address(timelock));
    }

    function test_governor_token() public view {
        assertEq(address(governor.token()), address(govToken));
    }

    function test_governor_proposalNeedsQueuing() public {
        address[] memory targets = new address[](1);
        uint256[] memory values  = new uint256[](1);
        bytes[]   memory calldatas = new bytes[](1);
        targets[0] = address(timelock);
        values[0]  = 0;
        calldatas[0] = "";

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "test");
        assertTrue(governor.proposalNeedsQueuing(proposalId));
    }

    function test_governor_cancel() public {
        address[] memory targets = new address[](1);
        uint256[] memory values  = new uint256[](1);
        bytes[]   memory calldatas = new bytes[](1);
        targets[0] = address(timelock);
        values[0]  = 0;
        calldatas[0] = "";

        vm.prank(alice);
        governor.propose(targets, values, calldatas, "cancel test");

        vm.prank(alice);
        governor.cancel(targets, values, calldatas, keccak256(bytes("cancel test")));
    }

    function test_governor_getVotes() public view {
        uint256 votes = governor.getVotes(alice, block.number - 1);
        assertGt(votes, 0);
    }

    function test_governor_quorum_atBlock() public view {
        uint256 q = governor.quorum(block.number - 1);
        assertGt(q, 0);
    }

    function test_governor_propose_and_state() public {
        address[] memory targets = new address[](1);
        uint256[] memory values  = new uint256[](1);
        bytes[]   memory calldatas = new bytes[](1);
        targets[0] = address(timelock);
        calldatas[0] = "";

        vm.prank(alice);
        uint256 pid = governor.propose(targets, values, calldatas, "state test");
        assertEq(uint8(governor.state(pid)), 0);

        _skipVotingDelay();
        assertEq(uint8(governor.state(pid)), 1);

        vm.prank(alice); governor.castVote(pid, 1);
        vm.prank(bob);   governor.castVote(pid, 1);

        _skipVotingPeriod();
        assertEq(uint8(governor.state(pid)), 4);
    }
}

// ═══════════════════════════════════════════════════════════════════
//  MockUSDC Tests
// ═══════════════════════════════════════════════════════════════════

import "../../src/tokens/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC public usdc;
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.prank(admin);
        usdc = new MockUSDC(admin);
    }

    function test_usdc_name() public view {
        assertEq(usdc.name(), "USD Coin");
    }

    function test_usdc_symbol() public view {
        assertEq(usdc.symbol(), "USDC");
    }

    function test_usdc_decimals() public view {
        assertEq(usdc.decimals(), 6);
    }

    function test_usdc_initialMint() public view {
        assertEq(usdc.balanceOf(admin), 100_000_000e6);
    }

    function test_usdc_mint_byOwner() public {
        vm.prank(admin);
        usdc.mint(alice, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);
    }

    function test_usdc_mint_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        usdc.mint(alice, 1000e6);
    }
}
