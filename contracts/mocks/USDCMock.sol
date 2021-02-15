// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.10;

import "@yield-protocol/utils/contracts/token/ERC20Permit.sol";


contract USDCMock is ERC20Permit {
    // Values taken from https://etherscan.io/address/0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48#readProxyContract
    // bytes32 constant override public DOMAIN_SEPARATOR = 0x06c37168a7db5138defc7866392bb87a741f9b3d104deb5094588ce041cae335;
    // bytes32 constant override public PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    constructor () public ERC20Permit("USD Coin", "USDC") {
        _setupDecimals(6);
    }

    function version() public pure override returns(string memory) { return "2"; }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }
}
