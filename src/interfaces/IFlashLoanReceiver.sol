// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

interface IFlashLoanReceiver {
    function onFlashLoan(
        address sender,
        uint256 token0Amount,
        uint256 token1Amount,
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external;
}
