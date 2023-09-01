// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {ISolidlySwapper} from "@periphery/swappers/interfaces/ISolidlySwapper.sol";
import {IBaseHealthCheck} from "@periphery/HealthCheck/IBaseHealthCheck.sol";

interface IStrategyInterface is IBaseHealthCheck, ISolidlySwapper {
    function setStable(address _token0, address _token1, bool _Stable) external;

    function setMinAmountToSell(uint256 _minAmountToSell) external;

    function setDontSwap(bool _dontSwap) external;

    function setPauseState(bool _state) external;

    function setEmergencyAdmin(address _emergencyAdmin) external;

    function maxImbalance() external view returns (uint256);

    function setMaxImbalance(uint256) external;
}
