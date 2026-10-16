// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {AgentDuel} from "../src/AgentDuel.sol";

/// @dev Deploys the token and performs the whole launch handoff inside a single constructor, so
/// everything happens in one transaction the way the factory's launchCustom does. The token's
/// msg.sender is this contract, not the account that created it.
contract OneTransactionLaunchFixture {
    AgentDuel public immutable token;
    uint256 public immutable mintedToFixture;
    address public immutable creator;

    constructor(address distributor, address poolManager, address remainderTo, uint256 swarmBps, uint256 poolBps) {
        creator = msg.sender;
        token = new AgentDuel();
        mintedToFixture = token.balanceOf(address(this));

        uint256 supply = token.totalSupply();
        uint256 swarm = (supply * swarmBps) / 10_000;
        uint256 pool = (supply * poolBps) / 10_000;
        require(token.transfer(distributor, swarm), "swarm transfer failed");
        require(token.transfer(poolManager, pool), "pool transfer failed");
        require(token.transfer(remainderTo, supply - swarm - pool), "remainder transfer failed");
    }
}

/// forge-config: default.fuzz.runs = 1000
contract AgentDuelEdgesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    AgentDuel private token;
    address private alice;
    address private bob;
    address private spender;

    function setUp() public {
        token = new AgentDuel();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment shape the launch depends on
    // ---------------------------------------------------------------------------------------------

    function test_contractIdentifierFitsThirtyTwoBytes() public pure {
        // The factory records the Solidity identifier as bytes32; a longer one cannot be described.
        assertLe(bytes(type(AgentDuel).name).length, 32);
        assertEq(type(AgentDuel).name, "AgentDuel");
    }

    function test_supplyIsExactlyOneBillionWholeTokens() public view {
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.totalSupply() / (10 ** uint256(token.decimals())), 1_000_000_000);
        assertEq(token.totalSupply() % (10 ** uint256(token.decimals())), 0);
    }

    function test_creationCodeTakesNoConstructorArguments() public {
        // Deploying the bare creation code succeeds: nothing is appended, nothing is required.
        bytes memory code = type(AgentDuel).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        assertTrue(deployed != address(0));
        assertEq(AgentDuel(deployed).balanceOf(address(this)), SUPPLY);
        assertEq(AgentDuel(deployed).totalSupply(), SUPPLY);
    }

    function test_launchHandoffCompletesInOneTransaction() public {
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("poolManager");
        address remainderTo = makeAddr("remainderTo");

        vm.prank(alice, alice);
        OneTransactionLaunchFixture fixture =
            new OneTransactionLaunchFixture(distributor, poolManager, remainderTo, 1_000, 8_000);
        AgentDuel launched = fixture.token();

        // The constructor minted to the fixture (the factory), never to the origin or the creator.
        assertEq(fixture.mintedToFixture(), SUPPLY);
        assertEq(fixture.creator(), alice);
        assertEq(launched.balanceOf(alice), 0);
        assertEq(launched.balanceOf(address(this)), 0);

        // Every launch flow arrived whole and the factory is empty afterwards.
        assertEq(launched.balanceOf(distributor), SUPPLY / 10);
        assertEq(launched.balanceOf(poolManager), SUPPLY * 8 / 10);
        assertEq(launched.balanceOf(remainderTo), SUPPLY / 10);
        assertEq(launched.balanceOf(address(fixture)), 0);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_twoDeploymentsAreIndependent() public {
        AgentDuel second = new AgentDuel();
        assertTrue(address(second) != address(token));
        token.transfer(alice, 5);
        assertEq(second.balanceOf(alice), 0);
        assertEq(second.balanceOf(address(this)), SUPPLY);
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY - 5);
    }

    function test_tokenContractAcceptsNoEther() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "plain value transfer accepted");
        (ok,) = address(token).call{value: 1}(abi.encodeWithSelector(IERC20.transfer.selector, alice, 0));
        assertFalse(ok, "payable transfer accepted");
        assertEq(address(token).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Error precedence: which rejection wins when more than one applies
    // ---------------------------------------------------------------------------------------------

    function test_zeroReceiverBeatsInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), type(uint256).max);
    }

    function test_insufficientAllowanceBeatsInsufficientBalance() public {
        // Alice holds 1 and approved 2; the spender asks for 3: the allowance is checked first.
        token.transfer(alice, 1);
        vm.prank(alice);
        token.approve(spender, 2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 2, 3));
        vm.prank(spender);
        token.transferFrom(alice, bob, 3);
        assertEq(token.allowance(alice, spender), 2);
        assertEq(token.balanceOf(alice), 1);
    }

    function test_insufficientAllowanceBeatsZeroReceiver() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 1);
    }

    function test_infiniteAllowanceStillCannotOverdrawOrReachZeroAddress() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10, 11));
        vm.prank(spender);
        token.transferFrom(alice, bob, 11);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(alice, address(0), 1);

        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 10);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowance edges
    // ---------------------------------------------------------------------------------------------

    function test_holderIsNotItsOwnSpenderWithoutApproval() public {
        token.transfer(alice, 5);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);

        vm.prank(alice);
        token.approve(alice, 5);
        vm.prank(alice);
        assertTrue(token.transferFrom(alice, bob, 5));
        assertEq(token.balanceOf(bob), 5);
        assertEq(token.allowance(alice, alice), 0);
    }

    function test_maxMinusOneAllowanceIsFiniteAndDecreases() public {
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.allowance(address(this), spender), type(uint256).max - 2);
    }

    function test_exactAllowanceIsConsumedToZeroAndOneMoreWeiIsRefused() public {
        token.approve(spender, 7);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 7);
        assertEq(token.allowance(address(this), spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
    }

    function test_approveOverwritesInsteadOfAccumulating() public {
        token.approve(spender, 100);
        token.approve(spender, 100);
        assertEq(token.allowance(address(this), spender), 100);
        token.approve(spender, type(uint256).max);
        token.approve(spender, 1);
        assertEq(token.allowance(address(this), spender), 1);
    }

    function test_spendingAllowanceEmitsNoApprovalEvent() public {
        token.approve(spender, 10);
        vm.recordLogs();
        vm.prank(spender);
        token.transferFrom(address(this), alice, 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
    }

    function test_approvalDoesNotMoveTokens() public {
        token.approve(spender, SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Tokens sent to the token contract are stuck, not burned
    // ---------------------------------------------------------------------------------------------

    function test_tokensSentToTokenContractAreStuck() public {
        assertTrue(token.transfer(address(token), 123));
        assertEq(token.balanceOf(address(token)), 123);
        assertEq(token.totalSupply(), SUPPLY);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(token), address(this), 1);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 123));
        vm.prank(alice);
        token.transferFrom(address(token), alice, 123);
        assertEq(token.balanceOf(address(token)), 123);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzzed properties
    // ---------------------------------------------------------------------------------------------

    /// @dev Any two non-zero accounts: a transfer out and back leaves both exactly where they began.
    function testFuzz_roundTripBetweenAnyTwoAccountsIsExact(uint160 fromSeed, uint160 toSeed, uint256 rawAmount)
        public
    {
        address from = _nonZero(fromSeed);
        address to = _nonZero(toSeed);
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        token.transfer(from, SUPPLY);

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        vm.prank(to);
        assertTrue(token.transfer(from, amount));
        assertEq(token.balanceOf(from), fromBefore);
        assertEq(token.balanceOf(to), toBefore);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev An empty account may always send zero to a non-zero receiver, and never anything more.
    function testFuzz_emptyAccountCanSendOnlyZero(uint160 fromSeed, uint160 toSeed, uint256 rawAmount) public {
        address from = _nonZero(fromSeed);
        address to = _nonZero(toSeed);
        uint256 amount = bound(rawAmount, 1, type(uint256).max);
        // Empty the deployer too, so the sender is empty whichever account the seed picked.
        token.transfer(makeAddr("vault"), SUPPLY);

        vm.prank(from);
        assertTrue(token.transfer(to, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, 0, amount));
        vm.prank(from);
        token.transfer(to, amount);
        assertEq(token.balanceOf(from), 0);
    }

    /// @dev The allowance is a plain overwrite for any owner, any spender and any amount.
    function testFuzz_approveReadsBackExactlyAndReplaces(
        uint160 ownerSeed,
        uint160 spenderSeed,
        uint256 first,
        uint256 second
    ) public {
        address owner = _nonZero(ownerSeed);
        address who = _nonZero(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(who, first));
        assertEq(token.allowance(owner, who), first);
        vm.prank(owner);
        assertTrue(token.approve(who, second));
        assertEq(token.allowance(owner, who), second);
        assertEq(token.balanceOf(who), 0);
        assertEq(token.balanceOf(owner), owner == address(this) ? SUPPLY : 0);
    }

    /// @dev Splitting the supply over several recipients loses nothing: the parts sum to the whole.
    function testFuzz_manyTransfersConserveSupply(uint256[8] memory rawAmounts) public {
        uint256 remaining = SUPPLY;
        uint256 sentTotal;
        for (uint256 i; i < rawAmounts.length; ++i) {
            uint256 amount = bound(rawAmounts[i], 0, remaining);
            address to = makeAddr(string.concat("recipient", vm.toString(i)));
            assertTrue(token.transfer(to, amount));
            assertEq(token.balanceOf(to), amount);
            remaining -= amount;
            sentTotal += amount;
        }
        assertEq(token.balanceOf(address(this)), SUPPLY - sentTotal);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Whichever of allowance and balance is short, the first shortfall decides the error and
    /// nothing moves. Covers all four combinations of enough/short allowance and balance.
    function testFuzz_transferFromOutcomeIsDecidedByAllowanceThenBalance(
        uint256 rawBalance,
        uint256 rawAllowance,
        uint256 rawAmount
    ) public {
        uint256 balance = bound(rawBalance, 0, SUPPLY);
        uint256 allowance = bound(rawAllowance, 0, SUPPLY);
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        token.transfer(alice, balance);
        vm.prank(alice);
        token.approve(spender, allowance);

        if (amount > allowance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount)
            );
        } else if (amount > balance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount)
            );
        }
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);

        bool succeeded = amount <= allowance && amount <= balance;
        assertEq(token.balanceOf(bob), succeeded ? amount : 0);
        assertEq(token.balanceOf(alice), succeeded ? balance - amount : balance);
        assertEq(token.allowance(alice, spender), succeeded ? allowance - amount : allowance);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Any selector with any arguments from a stranger: the supply cannot grow, the stranger
    /// cannot gain, and a holder cannot lose. Only the three standard entrypoints exist and none of
    /// them can do any of these things for an unfunded, unapproved caller.
    function testFuzz_unknownEntrypointsCannotMintStealOrFreeze(bytes4 selector, bytes memory args, uint160 callerSeed)
        public
    {
        address caller = _nonZero(callerSeed);
        if (caller == address(this) || caller == alice) caller = bob;
        token.transfer(alice, 1_000 ether);

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        ok;

        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.balanceOf(caller), 0, "a stranger gained tokens");
        assertEq(token.balanceOf(alice), 1_000 ether, "a holder lost tokens");
        assertEq(token.allowance(alice, caller), 0, "a stranger gained an allowance");

        vm.prank(alice);
        assertTrue(token.transfer(bob, 1_000 ether), "the holder can no longer transfer");
        assertEq(token.balanceOf(bob), 1_000 ether);
    }

    /// @dev Maps a fuzzed seed to a usable account without discarding runs.
    function _nonZero(uint160 seed) private pure returns (address) {
        return address(uint160(bound(uint256(seed), 1, type(uint160).max)));
    }
}
