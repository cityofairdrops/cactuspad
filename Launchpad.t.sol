// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract MockWETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }
}

contract MockPair {
    bool public minted;
    address public lpTo;

    function mint(address to) external returns (uint256) {
        minted = true;
        lpTo = to;
        return 1;
    }
}

contract MockFactory {
    function createPair(address, address) external returns (address) {
        return address(new MockPair());
    }
}

contract LaunchpadTest is Test {
    Launchpad lp;
    MockWETH weth;
    address treasury = address(0x7EA5);
    address alice = address(0xA11CE); // creator
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    function setUp() public {
        weth = new MockWETH();
        lp = new Launchpad(address(weth), address(new MockFactory()), treasury, 0);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    function _create() internal returns (address token) {
        vm.prank(alice);
        token = lp.createToken("Test", "TST", "ipfs://meta", address(0));
    }

    function test_createAndBuy() public {
        address token = _create();
        vm.prank(bob);
        lp.buy{value: 0.1 ether}(token, 0, address(0));
        assertGt(LaunchToken(token).balanceOf(bob), 0);
    }

    function test_sniperFeeDecays() public {
        address token = _create();
        assertEq(lp.currentFeeBps(token), 1050);
        vm.warp(block.timestamp + 150);
        assertEq(lp.currentFeeBps(token), 550);
        vm.warp(block.timestamp + 150);
        assertEq(lp.currentFeeBps(token), 50);
    }

    function test_earlyWalletCap() public {
        address token = _create();
        vm.prank(bob);
        vm.expectRevert(Launchpad.EarlyWalletCap.selector);
        lp.buy{value: 1 ether}(token, 0, address(0));
    }

    function test_creatorBuyIsLockedAndVests() public {
        vm.prank(alice);
        address token = lp.createToken{value: 0.05 ether}("Test", "TST", "ipfs://meta", address(0));
        assertEq(LaunchToken(token).balanceOf(alice), 0);
        (,,,,,,,, uint256 locked,) = lp.curves(token);
        assertGt(locked, 0);

        vm.warp(block.timestamp + 15 days);
        vm.prank(alice);
        lp.claimVested(token);
        assertApproxEqRel(LaunchToken(token).balanceOf(alice), locked / 2, 1e15);

        vm.warp(block.timestamp + 20 days);
        vm.prank(alice);
        lp.claimVested(token);
        assertEq(LaunchToken(token).balanceOf(alice), locked);
    }

    function test_creatorCapReverts() public {
        vm.prank(alice);
        vm.expectRevert(Launchpad.CreatorCap.selector);
        lp.createToken{value: 0.3 ether}("Test", "TST", "ipfs://meta", address(0));
    }

    function test_sellRoundTripNoProfit() public {
        address token = _create();
        vm.warp(block.timestamp + 400);
        uint256 before = bob.balance;
        vm.startPrank(bob);
        lp.buy{value: 0.5 ether}(token, 0, address(0));
        uint256 bal = LaunchToken(token).balanceOf(bob);
        LaunchToken(token).approve(address(lp), bal);
        lp.sell(token, bal, 0);
        vm.stopPrank();
        assertLt(bob.balance, before);
    }

    function test_pairLockedBeforeGraduation() public {
        address token = _create();
        vm.warp(block.timestamp + 400);
        vm.prank(bob);
        lp.buy{value: 0.1 ether}(token, 0, address(0));
        address pair = LaunchToken(token).pair();
        vm.prank(bob);
        vm.expectRevert(LaunchToken.PairLocked.selector);
        LaunchToken(token).transfer(pair, 1);
    }

    function test_feeSplitAndClaim() public {
        address token = _create();
        vm.warp(block.timestamp + 400); // 0.5% fee
        vm.prank(bob);
        lp.buy{value: 1 ether}(token, 0, carol);
        // fee = 0.005 ETH: creator 50%, referrer 15%, treasury 35%
        assertEq(lp.pending(alice), 0.0025 ether);
        assertEq(lp.pending(carol), 0.00075 ether);
        assertEq(lp.pending(treasury), 0.00175 ether);

        uint256 before = carol.balance;
        vm.prank(carol);
        lp.claim();
        assertEq(carol.balance - before, 0.00075 ether);
    }

    function test_graduation() public {
        address token = _create();
        vm.warp(block.timestamp + 400);
        uint256 before = bob.balance;
        vm.prank(bob);
        lp.buy{value: 10 ether}(token, 0, address(0));

        (,,, bool graduated,,,,,,) = lp.curves(token);
        assertTrue(graduated);
        assertEq(LaunchToken(token).balanceOf(bob), lp.CURVE_TOKENS());
        address pair = LaunchToken(token).pair();
        assertEq(LaunchToken(token).balanceOf(pair), lp.LP_TOKENS());
        assertTrue(MockPair(pair).minted());
        assertEq(MockPair(pair).lpTo(), lp.DEAD());
        assertGt(weth.balanceOf(pair), 3 ether);
        assertGt(bob.balance, before - 6 ether); // excess ETH was refunded
        assertTrue(LaunchToken(token).graduated());
    }
}
