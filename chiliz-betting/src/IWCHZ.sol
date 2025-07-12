// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/// @notice Interface minimaliste de Wrapped CHZ (WCHZ), équivalent WETH9
interface IWCHZ {
    /// @notice Dépose de l'ETH pour mint des WCHZ
    function deposit() external payable;
    /// @notice Retire de l'ETH en brûlant des WCHZ
    function withdraw(uint256 wad) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

