// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.10;


interface IDssPsm {
    function file(bytes32 what, uint256 data) external;
    function sellGem(address usr, uint256 gemAmt) external;
    function buyGem(address usr, uint256 gemAmt) external;
}
