// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Agent Duel
/// @notice Fixed-supply ERC-20. The deploying caller receives all tokens once.
contract AgentDuel is ERC20 {
    /// @notice One billion AD, expressed in the token's 18-decimal base units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @dev On a factory launch, msg.sender is the factory that distributes the supply.
    constructor() ERC20("Agent Duel", "AD") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
