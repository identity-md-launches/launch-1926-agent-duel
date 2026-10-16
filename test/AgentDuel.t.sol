// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {AgentDuel} from "../src/AgentDuel.sol";

/// @dev Local deployment fixture, never part of the launch.
contract TokenFactoryFixture {
    function deploy(bytes32 salt) external returns (AgentDuel) {
        return new AgentDuel{salt: salt}();
    }
}

contract AgentDuelTest is Test {
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

    function test_metadataAndEntireInitialSupply() public view {
        assertEq(token.name(), "Agent Duel");
        assertEq(token.symbol(), "AD");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_constructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        AgentDuel deployed = new AgentDuel();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(deployed));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_create2FactoryReceivesSupply() public {
        TokenFactoryFixture factory = new TokenFactoryFixture();
        bytes32 salt = keccak256("agent-duel-deployment-test");
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(type(AgentDuel).creationCode))
                    )
                )
            )
        );

        vm.prank(alice, alice);
        AgentDuel deployed = factory.deploy(salt);

        assertEq(address(deployed), predicted);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(alice), 0);
        assertEq(deployed.balanceOf(address(this)), 0);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    function test_transferDeliversExactAmountAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), alice, 42 ether);
        assertTrue(token.transfer(alice, 42 ether));
        assertEq(token.balanceOf(alice), 42 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 42 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_entireSupplyCanMoveAndReturn() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_selfTransferPreservesBalance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), address(this), SUPPLY);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToZeroRevertsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferOverBalanceRevertsWithoutChanges() public {
        token.transfer(alice, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10, 11));
        vm.prank(alice);
        token.transfer(bob, 11);
        assertEq(token.balanceOf(alice), 10);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferOverBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(alice, 1);
    }

    function test_maximumTransferAmountReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_approvalEmitsEventAndCanBeReplaced() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), spender, 100);
        assertTrue(token.approve(spender, 100));
        assertEq(token.allowance(address(this), spender), 100);
        assertTrue(token.approve(spender, 25));
        assertEq(token.allowance(address(this), spender), 25);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_approvalToZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 100);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_transferFromDeliversExactAmountAndConsumesAllowance() public {
        token.approve(spender, 100);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), alice, 40);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 40));
        assertEq(token.balanceOf(alice), 40);
        assertEq(token.balanceOf(address(this)), SUPPLY - 40);
        assertEq(token.allowance(address(this), spender), 60);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 60));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromSelfConsumesAllowanceButPreservesBalance() public {
        token.approve(spender, 100);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), 100));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_transferFromWithInfiniteAllowanceDoesNotReduceAllowance() public {
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertTrue(token.transferFrom(address(this), bob, 2));
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(bob), 2);
        assertEq(token.balanceOf(address(this)), SUPPLY - 3);
    }

    function test_zeroTransferFromNeedsNoAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_allowanceBelongsOnlyToApprovedSpender() public {
        token.approve(spender, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.allowance(address(this), spender), 100);
    }

    function test_revokedAllowanceCannotBeSpent() public {
        token.approve(spender, type(uint256).max);
        assertTrue(token.approve(spender, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_transferFromOverAllowanceRevertsWithoutChanges() public {
        token.approve(spender, 9);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 9, 10));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 10);
        assertEq(token.allowance(address(this), spender), 9);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferFromOverBalanceRollsBackAllowance() public {
        vm.prank(alice);
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10));
        vm.prank(spender);
        token.transferFrom(alice, bob, 10);
        assertEq(token.allowance(alice, spender), 10);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromToZeroRollsBackAllowance() public {
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 10);
        assertEq(token.allowance(address(this), spender), 10);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_deployerCannotSpendHolderBalanceWithoutApproval() public {
        token.transfer(alice, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(alice, address(this), 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100));
        assertEq(token.balanceOf(bob), 100);
    }

    function test_noMintBurnOrAdminEntrypointsForAnyone() public {
        token.transfer(alice, 100);
        bytes[] memory attempts = new bytes[](14);
        attempts[0] = abi.encodeWithSignature("mint(address,uint256)", bob, 1);
        attempts[1] = abi.encodeWithSignature("mint(uint256)", 1);
        attempts[2] = abi.encodeWithSignature("mint()");
        attempts[3] = abi.encodeWithSignature("burn(uint256)", 1);
        attempts[4] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1);
        attempts[5] = abi.encodeWithSignature("pause()");
        attempts[6] = abi.encodeWithSignature("blacklist(address)", alice);
        attempts[7] = abi.encodeWithSignature("freeze(address)", alice);
        attempts[8] = abi.encodeWithSignature("seize(address)", alice);
        attempts[9] = abi.encodeWithSignature("transferOwnership(address)", bob);
        attempts[10] = abi.encodeWithSignature("upgradeTo(address)", bob);
        attempts[11] = abi.encodeWithSignature("initialize(address)", bob);
        attempts[12] = abi.encodeWithSignature("setMinter(address)", bob);
        attempts[13] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);

        for (uint256 i; i < attempts.length; ++i) {
            (bool deployerSucceeded,) = address(token).call(attempts[i]);
            assertFalse(deployerSucceeded, "unexpected deployer privilege");
            vm.prank(bob);
            (bool strangerSucceeded,) = address(token).call(attempts[i]);
            assertFalse(strangerSucceeded, "unexpected public entrypoint");
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(alice), 100);
            assertEq(token.balanceOf(bob), 0);
        }
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100));
        assertEq(token.balanceOf(bob), 100);
    }

    function test_launchDistributionClaimsAndRoundTripTransfersAreExact() public {
        // Role addresses are local test actors; none are deployment parameters.
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("poolManager");
        address remainderRecipient = makeAddr("remainderRecipient");
        uint256 swarm = SUPPLY / 10;
        uint256 pool = SUPPLY * 8 / 10;
        uint256 remainder = SUPPLY - swarm - pool;

        assertTrue(token.transfer(distributor, swarm));
        assertTrue(token.transfer(poolManager, pool));
        assertTrue(token.transfer(remainderRecipient, remainder));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.balanceOf(remainderRecipient), remainder);

        vm.prank(distributor);
        assertTrue(token.transfer(alice, swarm));
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.balanceOf(alice), swarm);
        vm.prank(poolManager);
        assertTrue(token.transfer(bob, 100 ether));
        assertEq(token.balanceOf(bob), 100 ether);
        vm.prank(bob);
        assertTrue(token.transfer(poolManager, 100 ether));
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_runtimeFitsDeploymentLimitAndHasNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf2 && opcode != 0xf4 && opcode != 0xff, "forbidden opcode");
        }
    }

    function testFuzz_transferConservesSupply(address recipient, uint256 rawAmount) public {
        vm.assume(recipient != address(0) && recipient != address(this));
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_approvedTransferConservesSupply(uint256 rawAllowance, uint256 rawAmount) public {
        uint256 approved = bound(rawAllowance, 0, SUPPLY);
        uint256 amount = bound(rawAmount, 0, approved);
        token.approve(spender, approved);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(token.allowance(address(this), spender), approved - amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceAlwaysReverts(uint256 rawBalance, uint256 rawExcess) public {
        uint256 balance = bound(rawBalance, 0, SUPPLY);
        uint256 amount = balance + bound(rawExcess, 1, type(uint256).max - balance);
        token.transfer(alice, balance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount));
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveAllowanceAlwaysReverts(uint256 rawAllowance) public {
        uint256 approved = bound(rawAllowance, 0, SUPPLY - 1);
        token.approve(spender, approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, approved + 1)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, approved + 1);
        assertEq(token.allowance(address(this), spender), approved);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }
}
