// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.10;

import "@yield-protocol/utils/contracts/token/ERC20Permit.sol";


contract ERC20Mock is ERC20Permit {
    constructor () public ERC20Permit("Test", "TST") {
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }
}
