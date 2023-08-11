// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {BaseTokenizedStrategy} from "@tokenized-strategy/BaseTokenizedStrategy.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExchange} from "./interfaces/IExchange.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

import {SolidlySwapper} from "@periphery/swappers/SolidlySwapper.sol";

contract Tangible is BaseTokenizedStrategy, SolidlySwapper {
    using SafeERC20 for ERC20;

    uint256 internal constant MAX_BPS = 10_000;

    IExchange public constant exchange =
        IExchange(0x195F7B233947d51F4C3b756ad41a5Ddb34cEBCe0);

    // Token to swap DAI to
    address public constant usdr = 0x40379a439D4F6795B6fc9aa5687dB461677A2dBa;
    // Token that gets airdropped.
    address public constant TNGBL = 0x49e6A20f1BBdfEeC2a8222E052000BbB14EE6007;

    // Difference between ASSET and USDR decimals.
    uint256 internal constant scaler = 1e9;

    constructor(
        address _asset,
        string memory _name
    ) BaseTokenizedStrategy(_asset, _name) {
        ERC20(asset).safeApprove(address(exchange), type(uint256).max);
        ERC20(usdr).safeApprove(address(exchange), type(uint256).max);

        // Set uni swapper values
        // Set DAI as the base so can go straight from TNGBL => DAI
        base = usdr;
        router = 0x06374F57991CDc836E5A318569A910FE6456D230;
        // Set the asset => usdr pool as the stable version.
        _setStable(asset, usdr, true);
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
        uint256 outWithFee = (_amount -
            ((_amount * exchange.withdrawalFee()) / MAX_BPS)) * scaler;

        // If we can get more from the Pearl pool use that.
        if (_getAmountOut(usdr, asset, _amount) > outWithFee) {
            _swapFrom(usdr, asset, _amount, outWithFee);
        } else {
            exchange.swapToUnderlying(_amount, address(this));
        }
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
        returns (uint256 _totalAssets)
    {
        if (!TokenizedStrategy.isShutdown()) {
            // Swap any loose Tangible if applicable.
            // We can go directly -> USDR.
            // The swapper will do min checks.
            _swapFrom(TNGBL, usdr, ERC20(TNGBL).balanceOf(address(this)), 0);
        }

        _totalAssets =
            ERC20(asset).balanceOf(address(this)) +
            (ERC20(usdr).balanceOf(address(this)) * scaler);
    }

    function setStable(
        address _token0,
        address _token1,
        bool _stable
    ) external onlyManagement {
        _setStable(_token0, _token1, _stable);
    }

    function setMinAmountToSell(
        uint256 _minAmountToSell
    ) external onlyManagement {
        minAmountToSell = _minAmountToSell;
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
        _swapToUnderlying(_amount);
    }
}
