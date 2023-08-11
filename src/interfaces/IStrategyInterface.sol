// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {ISolidlySwapper} from "@periphery/swappers/interfaces/ISolidlySwapper.sol";

interface IStrategyInterface is IStrategy, ISolidlySwapper {
    function setStable(address _token0, address _token1, bool _Stable) external;

    function setMinAmountToSell(uint256 _minAmountToSell) external;
}
