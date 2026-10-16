// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentDuel} from "../src/AgentDuel.sol";

/// @dev Exercises only the public ERC-20 API and maintains an independent accounting model.
contract AgentDuelHandler is Test {
    AgentDuel public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(AgentDuel token_, address[4] memory actors_, uint256 initialBalance) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            expectedBalance[actors_[i]] = initialBalance;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 maximum = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        uint256 amount = bound(rawAmount, 0, maximum);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowed != type(uint256).max) {
            expectedAllowance[owner][spender] -= amount;
        }
    }
}

contract AgentDuelInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    AgentDuel private token;
    AgentDuelHandler private handler;
    address[4] private actors;

    function setUp() public {
        token = new AgentDuel();
        actors = [makeAddr("actor0"), makeAddr("actor1"), makeAddr("actor2"), makeAddr("actor3")];
        for (uint256 i; i < actors.length; ++i) {
            assertTrue(token.transfer(actors[i], SUPPLY / actors.length));
        }
        handler = new AgentDuelHandler(token, actors, SUPPLY / actors.length);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = AgentDuelHandler.transfer.selector;
        selectors[1] = AgentDuelHandler.approve.selector;
        selectors[2] = AgentDuelHandler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyBalancesAndAllowancesMatchModel() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);

        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            address owner = actors[i];
            uint256 balance = token.balanceOf(owner);
            assertEq(balance, handler.expectedBalance(owner));
            sum += balance;
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(owner, actors[j]), handler.expectedAllowance(owner, actors[j]));
            }
        }
        assertEq(sum, SUPPLY);
    }
}
