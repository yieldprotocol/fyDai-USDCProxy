// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.7;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./DaiJoinMock.sol";
import "./AuthGemJoinMock.sol";


// Peg Stability Module
// Allows anyone to go between Dai and the Gem by pooling the liquidity
// An optional fee is charged for incoming and outgoing transfers

contract DssPsmMock {

    IERC20 public dai;
    AuthGemJoinMock public gemJoin;
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
    constructor(IERC20 gem_, IERC20 dai_) public {
        gemJoin = new AuthGemJoinMock(address(gem_));
        daiJoin = new DaiJoinMock(address(dai_));
        dai = dai_;
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
    function setTin(uint256 tin_) external {
        tin = tin_;
    }
    function setTout(uint256 tout_) external {
        tout = tout_;
    }

    // --- Primary Functions ---
    function sellGem(address usr, uint256 gemAmt) external {
        uint256 fee = mul(gemAmt, tin) / WAD;
        uint256 daiAmt = sub(gemAmt, fee) * 1e12; // USDC has 6 decimals, Dai 18.
        gemJoin.join(address(this), gemAmt, msg.sender);
        daiJoin.exit(usr, daiAmt);

        emit SellGem(usr, gemAmt, fee);
    }

    function buyGem(address usr, uint256 gemAmt) external {
        uint256 fee = mul(gemAmt, tout) / WAD;
        uint256 daiAmt = add(gemAmt, fee) * 1e12; // USDC has 6 decimals, Dai 18.
        require(dai.transferFrom(msg.sender, address(this), daiAmt), "DssPsm/failed-transfer");
        daiJoin.join(address(this), daiAmt);
        gemJoin.exit(usr, gemAmt);

        emit BuyGem(usr, gemAmt, fee);
    }
}