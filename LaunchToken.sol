// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply token created by the Launchpad.
/// Until the token graduates, nobody except the Launchpad can send tokens to the
/// DEX pair. This stops pair pre-seeding / price-manipulation attacks on graduation.
contract LaunchToken is ERC20 {
    address public immutable launchpad;
    address public pair;
    bool public graduated;

    error NotLaunchpad();
    error PairAlreadySet();
    error PairLocked();

    constructor(string memory name_, string memory symbol_, uint256 supply, address launchpad_)
        ERC20(name_, symbol_)
    {
        launchpad = launchpad_;
        _mint(launchpad_, supply);
    }

    function setPair(address pair_) external {
        if (msg.sender != launchpad) revert NotLaunchpad();
        if (pair != address(0)) revert PairAlreadySet();
        pair = pair_;
    }

    function markGraduated() external {
        if (msg.sender != launchpad) revert NotLaunchpad();
        graduated = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!graduated && pair != address(0) && to == pair && from != launchpad) revert PairLocked();
        super._update(from, to, value);
    }
}
