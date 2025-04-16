// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MockEntryPoint
 * @dev A simple mock of EntryPoint for testing SuperPaymaster
 */
contract MockEntryPoint {
    mapping(address => uint256) public deposits;

    function depositTo(address account) external payable {
        deposits[account] += msg.value;
    }

    function withdrawTo(address payable to, uint256 amount) external {
        require(deposits[msg.sender] >= amount, "Insufficient deposit");
        deposits[msg.sender] -= amount;
        to.transfer(amount);
    }
} 