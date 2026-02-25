// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Multicall3
 * @notice Industry-standard batching contract deployed on many chains
 * @dev Based on the canonical Multicall3 implementation
 * 
 * Key Features:
 * - Aggregate multiple calls into one transaction
 * - Optional failure handling (tryAggregate)
 * - Block data helpers for simulation
 * - Value forwarding support
 * 
 * Deployed at the same address on 50+ chains:
 * 0xcA11bde05977b3631167028862bE2a173976CA11
 */
contract Multicall3 {

    // ═══════════════════════════════════════════════════════════════════════
    //                            STRUCTURES
    // ═══════════════════════════════════════════════════════════════════════

    struct Call {
        address target;
        bytes callData;
    }

    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Call3Value {
        address target;
        bool allowFailure;
        uint256 value;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         AGGREGATE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Aggregate calls, reverting on any failure
     * @param calls Array of Call structs
     * @return blockNumber Current block number
     * @return returnData Array of return data from each call
     */
    function aggregate(Call[] calldata calls) 
        external 
        payable 
        returns (uint256 blockNumber, bytes[] memory returnData) 
    {
        blockNumber = block.number;
        uint256 length = calls.length;
        returnData = new bytes[](length);
        
        for (uint256 i = 0; i < length; ) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
            require(success, "Multicall3: call failed");
            returnData[i] = ret;
            unchecked { ++i; }
        }
    }

    /**
     * @notice Aggregate calls without requiring success
     * @param requireSuccess Whether to revert on any failure
     * @param calls Array of Call structs
     * @return returnData Array of results
     */
    function tryAggregate(bool requireSuccess, Call[] calldata calls) 
        external 
        payable 
        returns (Result[] memory returnData) 
    {
        uint256 length = calls.length;
        returnData = new Result[](length);
        
        for (uint256 i = 0; i < length; ) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
            
            if (requireSuccess && !success) {
                revert("Multicall3: call failed");
            }
            
            returnData[i] = Result(success, ret);
            unchecked { ++i; }
        }
    }

    /**
     * @notice Same as tryAggregate but includes block number
     */
    function tryBlockAndAggregate(bool requireSuccess, Call[] calldata calls) 
        external
        payable 
        returns (uint256 blockNumber, bytes32 blockHash, Result[] memory returnData) 
    {
        blockNumber = block.number;
        blockHash = blockhash(block.number);
        returnData = this.tryAggregate(requireSuccess, calls);
    }

    /**
     * @notice Same as aggregate but includes block hash
     */
    function blockAndAggregate(Call[] calldata calls) 
        external
        payable 
        returns (uint256 blockNumber, bytes32 blockHash, bytes[] memory returnData) 
    {
        (blockNumber, returnData) = this.aggregate(calls);
        blockHash = blockhash(blockNumber);
    }

    /**
     * @notice Aggregate calls with per-call failure handling
     * @param calls Array of Call3 structs with allowFailure flag
     * @return returnData Array of results
     */
    function aggregate3(Call3[] calldata calls) 
        external 
        payable 
        returns (Result[] memory returnData) 
    {
        uint256 length = calls.length;
        returnData = new Result[](length);
        
        for (uint256 i = 0; i < length; ) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
            
            if (!calls[i].allowFailure && !success) {
                // Bubble up revert reason
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            
            returnData[i] = Result(success, ret);
            unchecked { ++i; }
        }
    }

    /**
     * @notice Aggregate calls with value and per-call failure handling
     * @param calls Array of Call3Value structs
     * @return returnData Array of results
     */
    function aggregate3Value(Call3Value[] calldata calls) 
        external 
        payable 
        returns (Result[] memory returnData) 
    {
        uint256 length = calls.length;
        returnData = new Result[](length);
        uint256 valAccumulator;
        
        for (uint256 i = 0; i < length; ) {
            uint256 callValue = calls[i].value;
            
            (bool success, bytes memory ret) = calls[i].target.call{value: callValue}(
                calls[i].callData
            );
            
            if (!calls[i].allowFailure && !success) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            
            returnData[i] = Result(success, ret);
            valAccumulator += callValue;
            
            unchecked { ++i; }
        }
        
        // Refund unused ETH
        uint256 refund = msg.value - valAccumulator;
        if (refund > 0) {
            (bool sent, ) = msg.sender.call{value: refund}("");
            require(sent, "Refund failed");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         BLOCK DATA HELPERS  
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get current block number
     */
    function getBlockNumber() external view returns (uint256 blockNumber) {
        blockNumber = block.number;
    }

    /**
     * @notice Get current block timestamp
     */
    function getCurrentBlockTimestamp() external view returns (uint256 timestamp) {
        timestamp = block.timestamp;
    }

    /**
     * @notice Get current block gas limit
     */
    function getCurrentBlockGasLimit() external view returns (uint256 gasLimit) {
        gasLimit = block.gaslimit;
    }

    /**
     * @notice Get current block coinbase (miner/validator)
     */
    function getCurrentBlockCoinbase() external view returns (address coinbase) {
        coinbase = block.coinbase;
    }

    /**
     * @notice Get current block difficulty (pre-merge) or prevrandao (post-merge)
     */
    function getCurrentBlockDifficulty() external view returns (uint256 difficulty) {
        difficulty = block.prevrandao;
    }

    /**
     * @notice Get block hash for a recent block
     * @param blockNumber Block number (must be within last 256 blocks)
     */
    function getBlockHash(uint256 blockNumber) external view returns (bytes32 blockHash) {
        blockHash = blockhash(blockNumber);
    }

    /**
     * @notice Get base fee of current block
     */
    function getBasefee() external view returns (uint256 basefee) {
        basefee = block.basefee;
    }

    /**
     * @notice Get chain ID
     */
    function getChainId() external view returns (uint256 chainId) {
        chainId = block.chainid;
    }

    /**
     * @notice Get ETH balance of an address
     */
    function getEthBalance(address addr) external view returns (uint256 balance) {
        balance = addr.balance;
    }

    /**
     * @notice Get last block hash
     */
    function getLastBlockHash() external view returns (bytes32 blockHash) {
        unchecked {
            blockHash = blockhash(block.number - 1);
        }
    }
}

/**
 * @title MulticallWithGasEstimation
 * @notice Extended Multicall with gas estimation per call
 * @dev Useful for frontend gas estimation
 */
contract MulticallWithGasEstimation is Multicall3 {

    struct CallWithGas {
        address target;
        bytes callData;
        uint256 gasLimit;
    }

    struct ResultWithGas {
        bool success;
        bytes returnData;
        uint256 gasUsed;
    }

    /**
     * @notice Aggregate calls and return gas used per call
     * @param calls Array of CallWithGas structs
     * @return returnData Array of results with gas data
     */
    function aggregateWithGas(CallWithGas[] calldata calls) 
        external 
        payable 
        returns (ResultWithGas[] memory returnData) 
    {
        uint256 length = calls.length;
        returnData = new ResultWithGas[](length);
        
        for (uint256 i = 0; i < length; ) {
            uint256 gasBefore = gasleft();
            
            uint256 callGas = calls[i].gasLimit > 0 ? calls[i].gasLimit : gasleft();
            
            (bool success, bytes memory ret) = calls[i].target.call{gas: callGas}(
                calls[i].callData
            );
            
            uint256 gasAfter = gasleft();
            
            returnData[i] = ResultWithGas(
                success,
                ret,
                gasBefore - gasAfter
            );
            
            unchecked { ++i; }
        }
    }

    /**
     * @notice Simulate calls without executing (for gas estimation)
     * @dev Uses staticcall to prevent state changes
     */
    function simulateAggregate(Call[] calldata calls) 
        external 
        view 
        returns (Result[] memory returnData) 
    {
        uint256 length = calls.length;
        returnData = new Result[](length);
        
        for (uint256 i = 0; i < length; ) {
            (bool success, bytes memory ret) = calls[i].target.staticcall(calls[i].callData);
            returnData[i] = Result(success, ret);
            unchecked { ++i; }
        }
    }
}
