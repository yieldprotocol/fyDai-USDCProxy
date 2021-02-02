// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.10;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface GemJoinLike { // TODO: Take maker interfaces out of @yield-protocol/utils and import the real pack from DSS
    function gem() external view returns(IERC20);
}
