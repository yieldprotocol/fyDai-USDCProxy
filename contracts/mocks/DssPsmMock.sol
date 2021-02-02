// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.7;


// Peg Stability Module
// Allows anyone to go between Dai and the Gem by pooling the liquidity
// An optional fee is charged for incoming and outgoing transfers

contract DssPsmMock {

    ERC20Like public dai;
    GemJoinMock public gemJoin;
    DaiJoinMock public daiJoin;

    uint256 public tin;         // toll in [wad]
    uint256 public tout;        // toll out [wad]

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event SellGem(address indexed owner, uint256 value, uint256 fee);
    event BuyGem(address indexed owner, uint256 value, uint256 fee);

    // --- Init ---
    constructor(address gemJoin_, address daiJoin_) public {
        gemJoin = GemJoinMock(gemJoin_);
        daiJoin = DaiJoinMock(daiJoin_);
        dai = ERC20Like(address(daiJoin.dai()));
        dai.approve(address(daiJoin), uint256(-1));
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---
    function file(bytes32 what, uint256 data) external {
        if (what == "tin") tin = data;
        else if (what == "tout") tout = data;
        else revert("DssPsm/file-unrecognized-param");

        emit File(what, data);
    }

    // --- Primary Functions ---
    function sellGem(address usr, uint256 gemAmt) external {
        uint256 fee = mul(gemAmt, tin) / WAD;
        uint256 daiAmt = sub(gemAmt, fee);
        gemJoin.join(address(this), gemAmt, msg.sender);
        daiJoin.exit(usr, daiAmt);

        emit SellGem(usr, gemAmt, fee);
    }

    function buyGem(address usr, uint256 gemAmt) external {
        uint256 fee = mul(gemAmt, tout) / WAD;
        uint256 daiAmt = add(gemAmt, fee);
        require(dai.transferFrom(msg.sender, address(this), daiAmt), "DssPsm/failed-transfer");
        daiJoin.join(address(this), daiAmt);
        gemJoin.exit(usr, gemAmt);

        emit BuyGem(usr, gemAmt, fee);
    }
}

interface ERC20Like {
    function approve(address,uint) external;
    function transfer(address,uint) external returns (bool);
    function transferFrom(address,address,uint) external returns (bool);
    function mint(address,uint) external;
    function burn(address,uint) external;
}

contract MockGemJoin {

    ERC20Like public gem;

    constructor(address gem_) public {
        gem = ERC20Like(gem_);
    }

    function join(address urn, uint256 wad, address _msgSender) external note {
        require(gem.transferFrom(_msgSender, address(this), wad), "GemJoin5/failed-transfer");
    }

    function exit(address guy, uint256 wad) external note {
        require(gem.transfer(guy, wad), "GemJoin5/failed-transfer");
    }
}

contract MockDaiJoin {
    ERC20Like public dai;  // Stablecoin Token

    constructor(address dai_) public {
        dai = ERC20Like(dai_);
    }

    function join(address usr, uint wad) external note {
        dai.burn(msg.sender, wad);
    }

    function exit(address usr, uint wad) external note {
        dai.mint(usr, wad);
    }
}