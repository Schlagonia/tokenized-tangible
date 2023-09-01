pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup} from "./utils/Setup.sol";

contract ShutdownTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_shudownCanWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        checkStrategyTotals(strategy, 0, 0, 0);

        assertGe(
            asset.balanceOf(user),
            (_amount * (MAX_BPS - exchange.withdrawalFee() - 1)) / MAX_BPS,
            "!final balance"
        );
    }

    function test_shudown_emergencyWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        checkStrategyTotals(strategy, _amount, _amount, 0);

        vm.prank(management);
        strategy.emergencyWithdraw(type(uint256).max);

        uint256 balance = asset.balanceOf(address(strategy));

        checkStrategyTotals(strategy, _amount, _amount - balance, balance);

        // Report the loss from the withdraw fee
        vm.prank(management);
        strategy.setDoHealthCheck(false);

        vm.prank(management);
        (, uint256 loss) = strategy.report();

        assertEq(loss, _amount - balance);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        checkStrategyTotals(strategy, 0, 0, 0);

        assertGe(
            asset.balanceOf(user),
            (_amount * (MAX_BPS - exchange.withdrawalFee() - 1)) / MAX_BPS,
            "!final balance"
        );
    }

    function test_shudown_emergencyWithdraw_dontSwap(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        checkStrategyTotals(strategy, _amount, _amount, 0);

        vm.prank(emergencyAdmin);
        strategy.setDontSwap(true);

        vm.prank(management);
        strategy.emergencyWithdraw(type(uint256).max);

        uint256 balance = asset.balanceOf(address(strategy));

        checkStrategyTotals(strategy, _amount, _amount - balance, balance);

        // Report the loss from the withdraw fee
        vm.prank(management);
        strategy.setDoHealthCheck(false);

        vm.prank(management);
        (, uint256 loss) = strategy.report();

        assertEq(loss, _amount - balance);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        checkStrategyTotals(strategy, 0, 0, 0);

        assertGe(
            asset.balanceOf(user),
            (_amount * (MAX_BPS - exchange.withdrawalFee() - 1)) / MAX_BPS,
            "!final balance"
        );
    }

    function test_pause(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);

        assertEq(strategy.availableDepositLimit(user), strategy.maxSwap());
        assertEq(strategy.availableWithdrawLimit(user), strategy.maxSwap());

        vm.prank(emergencyAdmin);
        strategy.setPauseState(true);

        assertEq(strategy.availableDepositLimit(user), 0);
        assertEq(strategy.availableWithdrawLimit(user), 0);

        // Withdraw should revert
        vm.expectRevert("ERC4626: withdraw more than max");
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // deposit should revert
        airdrop(asset, user, _amount);

        vm.prank(user);
        asset.approve(address(strategy), _amount);

        vm.expectRevert("ERC4626: deposit more than max");
        vm.prank(user);
        strategy.deposit(_amount, user);

        vm.prank(emergencyAdmin);
        strategy.setPauseState(false);

        assertEq(strategy.availableDepositLimit(user), strategy.maxSwap());
        assertEq(strategy.availableWithdrawLimit(user), strategy.maxSwap());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore +
                (_amount * (MAX_BPS - exchange.withdrawalFee())) /
                MAX_BPS,
            "!final balance"
        );
    }
}
