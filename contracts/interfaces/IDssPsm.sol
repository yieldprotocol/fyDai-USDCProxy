// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.10;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface GemJoinLike { // TODO: Split into own file
    function gem() external view returns(IERC20);
}

interface IDssPsm {
    function gemJoin() external view returns(GemJoinLike);
    function tin() external view returns(uint256);
    function tout() external view returns(uint256);
    function file(bytes32 what, uint256 data) external;
    function sellGem(address usr, uint256 gemAmt) external;
    function buyGem(address usr, uint256 gemAmt) external;
}
