// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.7;
import "./IERC20WithMint.sol";


contract DaiJoinMock {
    IERC20WithMint public dai;  // Stablecoin Token

    constructor(address dai_) public {
        dai = IERC20WithMint(dai_);
    }

    function join(address, uint wad) external {
        dai.burn(msg.sender, wad);
    }

    function exit(address usr, uint wad) external {
        dai.mint(usr, wad);
    }
}