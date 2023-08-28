// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {BaseTokenizedStrategy} from "@tokenized-strategy/BaseTokenizedStrategy.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExchange} from "./interfaces/IExchange.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

import {SolidlySwapper} from "@periphery/swappers/SolidlySwapper.sol";
import {BaseHealthCheck} from "@periphery/HealthCheck/BaseHealthCheck.sol";

contract Tangible is BaseHealthCheck, SolidlySwapper {
    using SafeERC20 for ERC20;

    modifier onlyEmergencyAuthorized() {
        _onlyEmergencyAuthorized();
        _;
    }

    function _onlyEmergencyAuthorized() internal view {
        require(
            msg.sender == emergencyAdmin ||
                msg.sender == TokenizedStrategy.management(),
            "!emergency authorized"
        );
    }

    IExchange public constant exchange =
        IExchange(0x195F7B233947d51F4C3b756ad41a5Ddb34cEBCe0);

    // Token to swap DAI to
    address public constant usdr = 0x40379a439D4F6795B6fc9aa5687dB461677A2dBa;
    // Token that gets airdropped.
    address public constant TNGBL = 0x49e6A20f1BBdfEeC2a8222E052000BbB14EE6007;

    // One in the assets decimals
    uint256 internal immutable one;

    // Difference between ASSET and USDR decimals.
    uint256 internal constant scaler = 1e9;

    // The maximum out of balance our pool quote can be.
    // In 1 of the asset and assumes asset/usdt are 1 - 1.
    uint256 public maxImbalance;

    // State of strategy.
    bool public paused;

    // For emergency withdraw. Can be used to
    // withdraw directly through the exchange.
    bool public dontSwap;

    // Can pause strategy.
    address public emergencyAdmin;

    constructor(
        address _asset,
        string memory _name
    ) BaseHealthCheck(_asset, _name) {
        ERC20(asset).safeApprove(address(exchange), type(uint256).max);
        ERC20(usdr).safeApprove(address(exchange), type(uint256).max);

        // Set uni swapper values
        // Set DAI as the base so can go straight from TNGBL => DAI
        base = usdr;
        router = 0x06374F57991CDc836E5A318569A910FE6456D230;
        // Set the asset => usdr pool as the stable version.
        _setStable(asset, usdr, true);

        // Lower the profit limit to 1% since we use swap values.
        _setProfitLimitRatio(100);

        one = 10 ** ERC20(_asset).decimals();
        // Default to a 10 bps for fees and slippage
        maxImbalance = (one * 10) / MAX_BPS;
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Should deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permsionless and thus can be sandwhiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy should attemppt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        _swapFromUnderlying(_amount);
    }

    function _swapFromUnderlying(uint256 _amount) internal {
        // Get the expected amount of `asset` out with the withdrawal fee.
        uint256 outWithFee = (_amount -
            ((_amount * exchange.depositFee()) / MAX_BPS)) / scaler;

        // If we can get more from the Pearl pool use that.
        if (_getAmountOut(asset, usdr, _amount) > outWithFee) {
            _swapFrom(asset, usdr, _amount, outWithFee);
        } else {
            exchange.swapFromUnderlying(_amount, address(this));
        }
    }

    /**
     * @dev Will attempt to free the '_amount' of 'asset'.
     *
     * The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permsionless and thus can be sandwhiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting puroposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        _swapToUnderlying(_amount);
    }

    function _swapToUnderlying(uint256 _amount) internal {
        // Adjust `_amount` down to the correct decimals and make sure
        // Its not more than we have from rounding.
        _amount = Math.min(
            _amount / scaler,
            ERC20(usdr).balanceOf(address(this))
        );

        // Get the expected amount of `asset` out with the withdrawal fee.
        uint256 outWithFee = _getAmountOutWithFee(_amount);

        // If we can get more from the Pearl pool use that.
        if (_getAmountOut(usdr, asset, _amount) > outWithFee) {
            _swapFrom(usdr, asset, _amount, outWithFee);
        } else {
            exchange.swapToUnderlying(_amount, address(this));
        }
    }

    // Convert USDT => DAI post any withdraw fees.
    function _getAmountOutWithFee(
        uint256 _amountIn
    ) internal view returns (uint256) {
        return
            (_amountIn - ((_amountIn * exchange.withdrawalFee()) / MAX_BPS)) *
            scaler;
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        checkHealth
        returns (uint256 _totalAssets)
    {
        require(!paused, "paused");

        if (!TokenizedStrategy.isShutdown()) {
            // Swap any loose Tangible if applicable.
            // We can go directly -> USDR.
            // The swapper will do min checks.
            _swapFrom(TNGBL, usdr, ERC20(TNGBL).balanceOf(address(this)), 0);
        }

        // Use the max we could currently for 1 USDR.
        uint256 rate = Math.max(
            _getAmountOut(usdr, asset, 1e9),
            _getAmountOutWithFee(1e9)
        );

        _totalAssets =
            ERC20(asset).balanceOf(address(this)) +
            // Multiply our balance by the current rate.
            (ERC20(usdr).balanceOf(address(this)) * rate) /
            scaler;

        // Health check the amounts since it relies on swap values.
        _executeHealthCheck(_totalAssets);
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overriden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     */
    function availableDepositLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // Can't deposit while paused.
        if (paused) return 0;

        // Can't deposit while the pool is imbalanced.
        if (!_poolIsBalanced()) return 0;

        return type(uint256).max;
    }

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overriden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies. It should never be lower than `totalIdle`.
     *
     *   EX:
     *       return TokenIzedStrategy.totalIdle();
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // Can't withdraw while paused.
        if (paused) return 0;

        // Can't withdraw while pool is imbalanced.
        if (!_poolIsBalanced()) return 0;

        return type(uint256).max;
    }

    /*//////////////////////////////////////////////////////////////
                        PERIPHERY SETTERS
    //////////////////////////////////////////////////////////////*/

    // Set stable bool mapping for the solidly swapper
    function setStable(
        address _token0,
        address _token1,
        bool _stable
    ) external onlyManagement {
        _setStable(_token0, _token1, _stable);
    }

    // Set the minimum we want the swapper to sell
    function setMinAmountToSell(
        uint256 _minAmountToSell
    ) external onlyManagement {
        minAmountToSell = _minAmountToSell;
    }

    function setPauseState(bool _state) external onlyEmergencyAuthorized {
        paused = _state;
    }

    function setDontSwap(bool _dontSwap) external onlyEmergencyAuthorized {
        dontSwap = _dontSwap;
    }

    function setEmergencyAdmin(
        address _emergencyAdmin
    ) external onlyManagement {
        emergencyAdmin = _emergencyAdmin;
    }

    function setMaxImbalance(
        uint256 _newSlippageBps
    ) external onlyEmergencyAuthorized {
        require(_newSlippageBps <= MAX_BPS, "max slippage");
        maxImbalance = (one * _newSlippageBps) / MAX_BPS;
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A seperate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // If we set `dontSwap` to true just go straight through the
        // exchange no matter what.
        if (dontSwap) {
            // Adjust `_amount` down to the correct decimals and make sure
            // Its not more than we have from rounding.
            _amount = Math.min(
                _amount / scaler,
                ERC20(usdr).balanceOf(address(this))
            );
            exchange.swapToUnderlying(_amount, address(this));
        } else {
            // Check the pool health.
            _checkHealth();
            // Else use the normal flow.
            _swapToUnderlying(_amount);
        }
    }

    /**
     * @notice Check important invariants for the strategy.
     * @dev This deafults to checking totalDebt but can be overriden
     * to check any important strategy specific invariants.
     */
    function _checkHealth() internal view override {
        require(_poolIsBalanced(), "imbalanced");
    }

    /** @dev Make sure the asset/USDR pool is not out of balance.
     *
     * Is used during the `checkHealth` modifier and the deposit/
     * withdraw limits to make sure the pool is within some range
     * and not being manipulated.
     *
     * Always check from USDR -> asset since USDR rebases and should
     * be a bigger amount of the pool.
     *
     * @return If the pool is in an acceptable balance.
     */
    function _poolIsBalanced() internal view returns (bool) {
        // Get the current spot rate in asset.
        uint256 amount = _getAmountOut(usdr, asset, 1e9);
        // Make sure its within our acceptable range.
        uint256 diff;
        if (amount < one) {
            unchecked {
                diff = one - amount;
            }
        } else {
            unchecked {
                diff = amount - one;
            }
        }

        return diff <= maxImbalance;
    }
}
