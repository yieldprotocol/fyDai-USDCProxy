// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.7;
import "./IERC20WithMint.sol";


contract GemJoinMock {

    IERC20WithMint public gem;

    constructor(address gem_) public {
        gem = IERC20WithMint(gem_);
    }

    function join(address, uint256 wad, address _msgSender) external {
        gem.burn(_msgSender, wad);
    }

    function exit(address guy, uint256 wad) external {
        gem.mint(guy, wad);
    }
}