// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.7;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface IERC20WithMint is IERC20 {
    function mint(address, uint256) external;
    function burn(address, uint256) external;
}
