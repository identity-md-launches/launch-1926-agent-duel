// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {AgentDuel} from "../src/AgentDuel.sol";

/// @notice Drives the token through succeeding AND failing calls in random order.
/// @dev The accepted handler in AgentDuel.invariant.t.sol only ever issues calls that succeed, so a
/// sequence there never shows what a rejected call leaves behind. This one deliberately overspends,
/// targets the zero address, spends without approval and approves the zero spender, asserts the
/// exact ERC-6093 error each time, and checks that a rejected call changed nothing. Every state
/// change that does happen is mirrored in ghost accounting the invariants compare against.
contract AgentDuelFailureHandler is Test {
    AgentDuel public immutable token;

    /// @dev Funded participants. Only these ever send or receive in a successful call.
    address[6] public actors;
    /// @dev Never funded, never approved. Must stay at zero and must never be able to move anything.
    address public immutable outsider;
    /// @dev The account the constructor minted to. Holds a share, never acts, is never approved: the
    /// address a token would most plausibly privilege, so it is the one that must have no privilege.
    address public immutable deployer;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    /// @dev Tokens sent to the token contract itself. Nothing can ever move them again.
    uint256 public ghostStuckInToken;
    /// @dev Totals that flowed through successful transfers, as a cross-check on conservation.
    uint256 public ghostTotalMoved;

    uint256 public succeededCalls;
    uint256 public rejectedCalls;

    constructor(AgentDuel token_, address[6] memory actors_, address outsider_, address deployer_) {
        token = token_;
        actors = actors_;
        outsider = outsider_;
        deployer = deployer_;
        for (uint256 i; i < actors_.length; ++i) {
            ghostBalance[actors_[i]] = token_.balanceOf(actors_[i]);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    /// @dev Amounts range up to twice the balance plus one, so roughly half the calls overspend.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 amount = bound(rawAmount, 0, balance * 2 + 1);

        if (amount > balance) {
            _expectTransferRevert(
                from,
                to,
                amount,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
            );
            return;
        }

        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostTotalMoved += amount;
        ++succeededCalls;
    }

    /// @dev The zero address is refused before the balance is even looked at, so a holder with
    /// nothing is refused for the same reason as a holder with everything.
    function transferToZero(uint256 fromSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        uint256 amount = bound(rawAmount, 0, token.balanceOf(from) * 2 + 1);
        _expectTransferRevert(
            from, address(0), amount, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    /// @dev The token contract is an ordinary receiver; what lands there is lost, not burned.
    function transferToTokenContract(uint256 fromSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        uint256 amount = bound(rawAmount, 0, token.balanceOf(from));
        vm.prank(from);
        assertTrue(token.transfer(address(token), amount), "transfer to token returned false");
        ghostBalance[from] -= amount;
        ghostStuckInToken += amount;
        ghostTotalMoved += amount;
        ++succeededCalls;
    }

    /// @dev The outsider holds nothing: a zero transfer succeeds, anything else is refused.
    function outsiderTransfer(uint256 toSeed, uint256 rawAmount) external {
        address to = _actor(toSeed);
        uint256 amount = bound(rawAmount, 0, 3);
        if (amount == 0) {
            vm.prank(outsider);
            assertTrue(token.transfer(to, 0), "zero transfer returned false");
            ++succeededCalls;
            return;
        }
        _expectTransferRevert(
            outsider,
            to,
            amount,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, outsider, 0, amount)
        );
    }

    // ---------------------------------------------------------------------------------------------
    // approve
    // ---------------------------------------------------------------------------------------------

    /// @dev Raw amounts on purpose: the fuzzer reaches zero, one and the maximum, and approving the
    /// maximum is the only way a later transferFrom leaves the allowance untouched.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
        ++succeededCalls;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        uint256 before = token.allowance(owner, address(0));
        vm.prank(owner);
        try token.approve(address(0), amount) {
            revert("approve(address(0)) succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)),
                "wrong error for zero spender"
            );
        }
        assertEq(token.allowance(owner, address(0)), before, "rejected approve changed an allowance");
        ++rejectedCalls;
    }

    // ---------------------------------------------------------------------------------------------
    // transferFrom
    // ---------------------------------------------------------------------------------------------

    /// @dev Amounts range above both the allowance and the balance. When both are short the
    /// allowance error must win, because the allowance is checked first and nothing is touched.
    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(owner);
        uint256 allowed = token.allowance(owner, spender);
        uint256 ceiling = allowed == type(uint256).max ? balance : (allowed > balance ? allowed : balance);
        // A finite allowance near the maximum would overflow the doubling; saturate instead.
        uint256 upper = ceiling > type(uint256).max / 2 - 1 ? type(uint256).max : ceiling * 2 + 1;
        uint256 amount = bound(rawAmount, 0, upper);

        if (allowed != type(uint256).max && amount > allowed) {
            _expectTransferFromRevert(
                owner,
                spender,
                to,
                amount,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
            return;
        }
        if (amount > balance) {
            _expectTransferFromRevert(
                owner,
                spender,
                to,
                amount,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
            );
            return;
        }

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");
        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        ghostTotalMoved += amount;
        if (allowed != type(uint256).max) {
            ghostAllowance[owner][spender] = allowed - amount;
        }
        ++succeededCalls;
    }

    /// @dev An approved spender still cannot send to the zero address, and keeps its allowance.
    function transferFromToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 amount = bound(rawAmount, 0, allowed == type(uint256).max ? token.balanceOf(owner) : allowed);
        _expectTransferFromRevert(
            owner,
            spender,
            address(0),
            amount,
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    /// @dev Nobody ever approves the outsider, so it can spend nothing but zero from anyone.
    function outsiderTransferFrom(uint256 ownerSeed, uint256 toSeed, uint256 rawAmount) external {
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(rawAmount, 0, token.balanceOf(owner) + 1);
        if (amount == 0) {
            vm.prank(outsider);
            assertTrue(token.transferFrom(owner, to, 0), "zero transferFrom returned false");
            ++succeededCalls;
            return;
        }
        _expectTransferFromRevert(
            owner,
            outsider,
            to,
            amount,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, outsider, 0, amount)
        );
    }

    /// @dev The deployer has no standing over anyone else's balance: without an approval it is
    /// refused exactly like a stranger, and its own balance is not a source for anyone either.
    function deployerSpendsWithoutAllowance(uint256 ownerSeed, uint256 toSeed, uint256 rawAmount) external {
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(rawAmount, 1, token.balanceOf(owner) + 1);
        _expectTransferFromRevert(
            owner,
            deployer,
            to,
            amount,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, amount)
        );
        // And the reverse: an actor cannot draw on the deployer's untouched share.
        _expectTransferFromRevert(
            deployer,
            owner,
            to,
            1,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, owner, 0, 1)
        );
    }

    /// @dev A holder is not implicitly its own spender: transferFrom(self, ...) needs an allowance.
    function selfSpendWithoutAllowance(uint256 ownerSeed, uint256 toSeed, uint256 rawAmount) external {
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, owner);
        uint256 amount = bound(rawAmount, allowed == type(uint256).max ? 0 : allowed + 1, type(uint256).max);
        if (allowed == type(uint256).max) {
            // Self-approved to the maximum: behaves like any infinite-allowance spender; skip the
            // revert expectation and leave the ordinary transferFrom path to cover it.
            amount = bound(amount, token.balanceOf(owner) + 1, type(uint256).max);
            _expectTransferFromRevert(
                owner,
                owner,
                to,
                amount,
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, owner, token.balanceOf(owner), amount
                )
            );
            return;
        }
        _expectTransferFromRevert(
            owner,
            owner,
            to,
            amount,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, owner, allowed, amount)
        );
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _expectTransferRevert(address from, address to, uint256 amount, bytes memory expected) private {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(from);
        try token.transfer(to, amount) {
            revert("transfer that should fail succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, expected, "unexpected transfer error");
        }

        assertEq(token.balanceOf(from), fromBefore, "rejected transfer changed sender balance");
        assertEq(token.balanceOf(to), toBefore, "rejected transfer changed receiver balance");
        assertEq(token.totalSupply(), supplyBefore, "rejected transfer changed supply");
        ++rejectedCalls;
    }

    function _expectTransferFromRevert(
        address owner,
        address spender,
        address to,
        uint256 amount,
        bytes memory expected
    ) private {
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        uint256 allowanceBefore = token.allowance(owner, spender);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            revert("transferFrom that should fail succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, expected, "unexpected transferFrom error");
        }

        assertEq(token.balanceOf(owner), ownerBefore, "rejected transferFrom changed owner balance");
        assertEq(token.balanceOf(to), toBefore, "rejected transferFrom changed receiver balance");
        assertEq(token.allowance(owner, spender), allowanceBefore, "rejected transferFrom changed allowance");
        assertEq(token.totalSupply(), supplyBefore, "rejected transferFrom changed supply");
        ++rejectedCalls;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract AgentDuelFailureInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    AgentDuel private token;
    AgentDuelFailureHandler private handler;
    address[6] private actors;
    address private outsider;
    /// @dev What the deployer keeps after funding the actors. Nobody in the handler acts for it.
    uint256 private deployerShare;

    function setUp() public {
        token = new AgentDuel();
        outsider = makeAddr("outsider");

        // Uneven funding so the actors sit at very different scales: one whale, one at one wei,
        // one empty, the rest in between. The deployer keeps the remainder untouched.
        uint256[6] memory shares = [SUPPLY / 2, SUPPLY / 10, 1_000 ether, 1, 0, SUPPLY / 100];
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            if (shares[i] > 0) assertTrue(token.transfer(actors[i], shares[i]));
        }
        deployerShare = token.balanceOf(address(this));
        assertGt(deployerShare, 0);

        handler = new AgentDuelFailureHandler(token, actors, outsider, address(this));

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = AgentDuelFailureHandler.transfer.selector;
        selectors[1] = AgentDuelFailureHandler.transferToZero.selector;
        selectors[2] = AgentDuelFailureHandler.transferToTokenContract.selector;
        selectors[3] = AgentDuelFailureHandler.outsiderTransfer.selector;
        selectors[4] = AgentDuelFailureHandler.approve.selector;
        selectors[5] = AgentDuelFailureHandler.approveZeroSpender.selector;
        selectors[6] = AgentDuelFailureHandler.transferFrom.selector;
        selectors[7] = AgentDuelFailureHandler.transferFromToZero.selector;
        selectors[8] = AgentDuelFailureHandler.outsiderTransferFrom.selector;
        selectors[9] = AgentDuelFailureHandler.selfSpendWithoutAllowance.selector;
        selectors[10] = AgentDuelFailureHandler.deployerSpendsWithoutAllowance.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The supply is fixed at construction: no sequence of calls, accepted or rejected, moves it.
    function invariant_totalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    /// @dev Everything is somewhere: actors, the idle deployer, and what was sent into the token.
    function invariant_everyTokenIsAccountedFor() public view {
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(address(token));
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "tokens leaked to or from an unknown account");
        assertEq(token.balanceOf(address(token)), handler.ghostStuckInToken(), "stuck amount drifted");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(handler)), 0, "the handler holds tokens");
    }

    /// @dev Each actor holds exactly what the ghost model says it received minus what it sent.
    function invariant_balancesMatchGhostModel() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.ghostBalance(actors[i]), "actor balance drifted from model");
        }
    }

    /// @dev Allowances change only through approve by the owner or transferFrom by the spender.
    function invariant_allowancesMatchGhostModel() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.ghostAllowance(actors[i], actors[j]),
                    "allowance drifted from model"
                );
            }
            assertEq(token.allowance(actors[i], outsider), 0, "outsider gained an allowance");
            assertEq(token.allowance(actors[i], address(this)), 0, "deployer gained an allowance");
            assertEq(token.allowance(address(this), actors[i]), 0, "deployer granted an allowance");
            assertEq(token.allowance(actors[i], address(0)), 0, "zero spender gained an allowance");
        }
    }

    /// @dev A holder that never signs anything keeps exactly what it had, whatever everyone else does.
    function invariant_idleHolderIsUntouchable() public view {
        assertEq(token.balanceOf(address(this)), deployerShare, "the idle deployer's balance moved");
        assertEq(token.balanceOf(outsider), 0, "the outsider acquired tokens");
    }

    /// @dev Non-vacuity: a run that never reached a rejected path would prove nothing about them.
    function afterInvariant() public view {
        assertGt(handler.succeededCalls(), 0, "no call succeeded in this run");
        assertGt(handler.rejectedCalls(), 0, "no call was rejected in this run");
    }
}
