// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.5.12;


interface AuthGemJoinAbstract {
    function wards(address) external view returns (uint256);
    function rely(address) external;
    function deny(address) external;
    function vat() external view returns (address);
    function ilk() external view returns (bytes32);
    function gem() external view returns (address);
    function dec() external view returns (uint256);
    function live() external view returns (uint256);
    function cage() external;
    function join(address, uint256, address) external;
    function exit(address, uint256) external;
}