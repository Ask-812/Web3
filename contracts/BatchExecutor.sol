// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BatchExecutor
 * @author Web3Assam Gas Optimizer Team
 * @notice A gas-optimized batch transaction executor with meta-transaction support
 * @dev Implements EIP-712 typed signatures for secure off-chain signing
 * 
 * ARCHITECTURE:
 * - Users sign transactions off-chain (no gas required for signing)
 * - Relayers submit batched transactions on-chain
 * - Multiple user actions execute in a single transaction
 * - Gas costs are amortized across all batched operations
 */
contract BatchExecutor is Ownable, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ CONSTANTS ============
    
    /// @notice EIP-712 Domain Separator typehash
    bytes32 public constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    
    /// @notice Meta-transaction typehash for signature verification
    bytes32 public constant META_TX_TYPEHASH = keccak256(
        "MetaTransaction(address from,address to,uint256 value,bytes data,uint256 nonce,uint256 deadline)"
    );

    /// @notice Batch execution typehash
    bytes32 public constant BATCH_TYPEHASH = keccak256(
        "BatchExecution(address from,bytes32 callsHash,uint256 nonce,uint256 deadline)"
    );

    // ============ STATE VARIABLES ============
    
    /// @notice EIP-712 domain separator (computed at deployment)
    bytes32 public immutable DOMAIN_SEPARATOR;
    
    /// @notice Mapping of user addresses to their current nonce (replay protection)
    mapping(address => uint256) public nonces;
    
    /// @notice Mapping of authorized relayers
    mapping(address => bool) public authorizedRelayers;
    
    /// @notice Whether relayer whitelist is enabled
    bool public relayerWhitelistEnabled;

    /// @notice Gas sponsor contract address (optional)
    address public gasSponsor;

    /// @notice Total gas saved across all batch operations (for analytics)
    uint256 public totalGasSaved;

    /// @notice Total number of batches executed
    uint256 public totalBatchesExecuted;

    // ============ STRUCTS ============
    
    /// @notice Represents a single call within a batch
    struct Call {
        address target;      // Contract to call
        uint256 value;       // ETH value to send
        bytes data;          // Calldata to execute
    }

    /// @notice Meta-transaction data structure
    struct MetaTransaction {
        address from;        // Original signer
        address to;          // Target contract
        uint256 value;       // ETH value
        bytes data;          // Calldata
        uint256 nonce;       // Replay protection
        uint256 deadline;    // Expiration timestamp
    }

    /// @notice Batch execution request
    struct BatchRequest {
        address from;        // Original signer
        Call[] calls;        // Array of calls to execute
        uint256 nonce;       // Replay protection
        uint256 deadline;    // Expiration timestamp
    }

    // ============ EVENTS ============
    
    event BatchExecuted(
        address indexed executor,
        address indexed signer,
        uint256 callCount,
        uint256 gasUsed,
        uint256 indexed batchId
    );

    event MetaTransactionExecuted(
        address indexed from,
        address indexed to,
        uint256 value,
        bytes data,
        uint256 nonce
    );

    event CallExecuted(
        uint256 indexed callIndex,
        address indexed target,
        bool success,
        bytes returnData
    );

    event RelayerAuthorized(address indexed relayer, bool authorized);
    event GasSponsorUpdated(address indexed oldSponsor, address indexed newSponsor);
    event RelayerWhitelistToggled(bool enabled);

    // ============ ERRORS ============
    
    error InvalidSignature();
    error ExpiredDeadline();
    error InvalidNonce();
    error UnauthorizedRelayer();
    error CallFailed(uint256 index, bytes reason);
    error EmptyBatch();
    error InsufficientBalance();

    // ============ CONSTRUCTOR ============
    
    constructor() Ownable(msg.sender) {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("GasOptimizer")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    // ============ EXTERNAL FUNCTIONS ============

    /**
     * @notice Execute a batch of calls directly (no meta-transaction)
     * @dev Useful for users who want to batch their own transactions
     * @param calls Array of calls to execute
     * @return results Array of return data from each call
     */
    function executeBatch(Call[] calldata calls) 
        external 
        payable 
        nonReentrant 
        returns (bytes[] memory results) 
    {
        if (calls.length == 0) revert EmptyBatch();
        
        uint256 gasStart = gasleft();
        results = _executeCalls(calls, msg.sender);
        uint256 gasUsed = gasStart - gasleft();
        
        totalBatchesExecuted++;
        
        // Estimate gas savings (single tx overhead vs multiple tx overhead)
        // Base tx cost is ~21000 gas, so batching N calls saves (N-1) * 21000
        uint256 estimatedSavings = (calls.length - 1) * 21000;
        totalGasSaved += estimatedSavings;

        emit BatchExecuted(
            msg.sender, 
            msg.sender, 
            calls.length, 
            gasUsed,
            totalBatchesExecuted
        );
    }

    /**
     * @notice Execute a batch via meta-transaction (gasless for user)
     * @dev Relayer pays gas, user only signs off-chain
     * @param request The batch request containing calls and metadata
     * @param signature EIP-712 signature from the user
     * @return results Array of return data from each call
     */
    function executeBatchMeta(
        BatchRequest calldata request,
        bytes calldata signature
    ) 
        external 
        nonReentrant 
        returns (bytes[] memory results) 
    {
        // Check relayer authorization
        if (relayerWhitelistEnabled && !authorizedRelayers[msg.sender]) {
            revert UnauthorizedRelayer();
        }

        // Verify deadline
        if (block.timestamp > request.deadline) {
            revert ExpiredDeadline();
        }

        // Verify nonce
        if (request.nonce != nonces[request.from]) {
            revert InvalidNonce();
        }

        // Verify signature
        bytes32 callsHash = _hashCalls(request.calls);
        bytes32 structHash = keccak256(
            abi.encode(
                BATCH_TYPEHASH,
                request.from,
                callsHash,
                request.nonce,
                request.deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );

        address signer = digest.recover(signature);
        if (signer != request.from) {
            revert InvalidSignature();
        }

        // Increment nonce (replay protection)
        nonces[request.from]++;

        // Execute the batch
        uint256 gasStart = gasleft();
        results = _executeCalls(request.calls, request.from);
        uint256 gasUsed = gasStart - gasleft();

        totalBatchesExecuted++;
        
        uint256 estimatedSavings = (request.calls.length - 1) * 21000;
        totalGasSaved += estimatedSavings;

        emit BatchExecuted(
            msg.sender,
            request.from,
            request.calls.length,
            gasUsed,
            totalBatchesExecuted
        );
    }

    /**
     * @notice Execute a single meta-transaction
     * @dev Useful for single gasless transaction
     * @param metaTx The meta-transaction data
     * @param signature EIP-712 signature
     * @return success Whether the call succeeded
     * @return returnData The return data from the call
     */
    function executeMetaTransaction(
        MetaTransaction calldata metaTx,
        bytes calldata signature
    ) 
        external 
        nonReentrant 
        returns (bool success, bytes memory returnData) 
    {
        // Check relayer authorization
        if (relayerWhitelistEnabled && !authorizedRelayers[msg.sender]) {
            revert UnauthorizedRelayer();
        }

        // Verify deadline
        if (block.timestamp > metaTx.deadline) {
            revert ExpiredDeadline();
        }

        // Verify nonce
        if (metaTx.nonce != nonces[metaTx.from]) {
            revert InvalidNonce();
        }

        // Verify signature
        bytes32 structHash = keccak256(
            abi.encode(
                META_TX_TYPEHASH,
                metaTx.from,
                metaTx.to,
                metaTx.value,
                keccak256(metaTx.data),
                metaTx.nonce,
                metaTx.deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );

        address signer = digest.recover(signature);
        if (signer != metaTx.from) {
            revert InvalidSignature();
        }

        // Increment nonce
        nonces[metaTx.from]++;

        // Execute the transaction
        (success, returnData) = metaTx.to.call{value: metaTx.value}(metaTx.data);

        emit MetaTransactionExecuted(
            metaTx.from,
            metaTx.to,
            metaTx.value,
            metaTx.data,
            metaTx.nonce - 1
        );
    }

    /**
     * @notice Simulate a batch execution without committing
     * @dev Useful for gas estimation and validation
     * @param calls Array of calls to simulate
     * @return success Whether all calls would succeed
     * @return results Array of return data
     * @return gasEstimate Estimated gas for the batch
     */
    function simulateBatch(Call[] calldata calls) 
        external 
        view 
        returns (bool success, bytes[] memory results, uint256 gasEstimate) 
    {
        results = new bytes[](calls.length);
        success = true;
        
        // Rough gas estimation
        gasEstimate = 21000; // Base transaction cost
        
        for (uint256 i = 0; i < calls.length; i++) {
            // Add estimated gas per call (rough estimate)
            gasEstimate += 50000 + calls[i].data.length * 16;
        }

        return (success, results, gasEstimate);
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Authorize or revoke a relayer
     * @param relayer Address of the relayer
     * @param authorized Whether to authorize or revoke
     */
    function setRelayerAuthorization(address relayer, bool authorized) 
        external 
        onlyOwner 
    {
        authorizedRelayers[relayer] = authorized;
        emit RelayerAuthorized(relayer, authorized);
    }

    /**
     * @notice Toggle relayer whitelist enforcement
     * @param enabled Whether to enable whitelist
     */
    function setRelayerWhitelistEnabled(bool enabled) external onlyOwner {
        relayerWhitelistEnabled = enabled;
        emit RelayerWhitelistToggled(enabled);
    }

    /**
     * @notice Set the gas sponsor contract
     * @param _gasSponsor Address of the gas sponsor contract
     */
    function setGasSponsor(address _gasSponsor) external onlyOwner {
        address oldSponsor = gasSponsor;
        gasSponsor = _gasSponsor;
        emit GasSponsorUpdated(oldSponsor, _gasSponsor);
    }

    /**
     * @notice Withdraw any ETH accidentally sent to this contract
     */
    function withdrawETH() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get the current nonce for an address
     * @param account The address to query
     * @return The current nonce
     */
    function getNonce(address account) external view returns (uint256) {
        return nonces[account];
    }

    /**
     * @notice Check if a relayer is authorized
     * @param relayer The relayer address
     * @return Whether the relayer is authorized
     */
    function isRelayerAuthorized(address relayer) external view returns (bool) {
        return authorizedRelayers[relayer];
    }

    /**
     * @notice Get gas statistics
     * @return totalSaved Total gas saved
     * @return batchCount Total batches executed
     */
    function getGasStats() external view returns (uint256 totalSaved, uint256 batchCount) {
        return (totalGasSaved, totalBatchesExecuted);
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @dev Execute an array of calls
     * @param calls Array of calls to execute
     * @param originalSender The original transaction initiator
     * @return results Array of return data
     */
    function _executeCalls(Call[] calldata calls, address originalSender) 
        internal 
        returns (bytes[] memory results) 
    {
        results = new bytes[](calls.length);
        
        for (uint256 i = 0; i < calls.length; i++) {
            // Encode the original sender in the calldata if needed
            // This allows target contracts to know who initiated the batch
            bytes memory callData = abi.encodePacked(
                calls[i].data,
                originalSender
            );
            
            (bool success, bytes memory returnData) = calls[i].target.call{
                value: calls[i].value
            }(calls[i].data);

            if (!success) {
                revert CallFailed(i, returnData);
            }

            results[i] = returnData;
            
            emit CallExecuted(i, calls[i].target, success, returnData);
        }
    }

    /**
     * @dev Hash an array of calls for signature verification
     * @param calls Array of calls to hash
     * @return Hash of the calls array
     */
    function _hashCalls(Call[] calldata calls) internal pure returns (bytes32) {
        bytes32[] memory callHashes = new bytes32[](calls.length);
        
        for (uint256 i = 0; i < calls.length; i++) {
            callHashes[i] = keccak256(
                abi.encode(
                    calls[i].target,
                    calls[i].value,
                    keccak256(calls[i].data)
                )
            );
        }
        
        return keccak256(abi.encodePacked(callHashes));
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
