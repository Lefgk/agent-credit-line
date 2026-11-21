// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentCreditVault} from "./AgentCreditVault.sol";

/// @title AgentCreditVaultFactory
/// @notice Deploys one AgentCreditVault per call, owned by the caller, pinned to this factory's USDC.
contract AgentCreditVaultFactory {
    address public immutable usdc;
    mapping(address owner => address[]) internal _vaultsOf;

    event VaultCreated(address indexed owner, address indexed vault);

    error ZeroAddress();

    constructor(address usdc_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
    }

    function createVault() external returns (address vault) {
        vault = address(new AgentCreditVault(msg.sender, usdc));
        _vaultsOf[msg.sender].push(vault);
        emit VaultCreated(msg.sender, vault);
    }

    function vaultsOf(address owner) external view returns (address[] memory) {
        return _vaultsOf[owner];
    }
}
