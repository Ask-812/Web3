// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Counter
 * @dev Simple counter contract for testing Multicall3 and batch operations
 */
contract Counter {
    uint256 public count;
    
    event CountChanged(uint256 newCount);
    
    function increment() external {
        count++;
        emit CountChanged(count);
    }
    
    function decrement() external {
        require(count > 0, "Counter: cannot decrement below zero");
        count--;
        emit CountChanged(count);
    }
    
    function add(uint256 value) external {
        count += value;
        emit CountChanged(count);
    }
    
    function reset() external {
        count = 0;
        emit CountChanged(count);
    }
    
    function getCount() external view returns (uint256) {
        return count;
    }
}
