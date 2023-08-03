// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

interface IExchange {
    function swapToUnderlying(uint256 amountIn, address to)
        external
        returns (uint256);

    function swapFromUnderlying(uint256 amountIn, address to)
        external
        returns (uint256 amountOut);

    function depositFee() external view returns (uint256);

    function withdrawalFee() external view returns (uint256);
}
