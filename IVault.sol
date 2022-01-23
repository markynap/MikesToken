//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IVault {
    function deleteBag(uint256 nTokens) external returns(bool);
    function reflectYourTokens(uint256 nTokens) external;
}