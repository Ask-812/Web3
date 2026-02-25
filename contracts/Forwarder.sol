// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";

/**
 * @title Forwarder
 * @author Web3Assam Gas Optimizer Team
 * @notice EIP-2771 compliant trusted forwarder for meta-transactions
 * @dev Standard forwarder that any EIP-2771 compatible contract can trust
 * 
 * EIP-2771 FLOW:
 * 1. User signs a meta-transaction off-chain
 * 2. Relayer submits the signed transaction to this Forwarder
 * 3. Forwarder verifies signature and forwards to target contract
 * 4. Target contract extracts original sender from msg.data (last 20 bytes)
 */
contract Forwarder is Nonces {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ CONSTANTS ============

    bytes32 private constant FORWARD_REQUEST_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );

    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    // ============ STATE VARIABLES ============

    bytes32 public immutable DOMAIN_SEPARATOR;
    string public constant NAME = "GasOptimizer Forwarder";
    string public constant VERSION = "1";

    // ============ STRUCTS ============

    /**
     * @notice Forward request structure
     * @param from Original sender (signer)
     * @param to Target contract
     * @param value ETH to send
     * @param gas Gas limit for the call
     * @param nonce Replay protection nonce
     * @param deadline Expiration timestamp
     * @param data Calldata to forward
     */
    struct ForwardRequest {
        address from;
        address to;
        uint256 value;
        uint256 gas;
        uint256 nonce;
        uint48 deadline;
        bytes data;
    }

    // ============ EVENTS ============

    event Forwarded(
        address indexed from,
        address indexed to,
        uint256 value,
        uint256 gas,
        bool success,
        bytes returnData
    );

    // ============ ERRORS ============

    error InvalidSignature();
    error ExpiredRequest();
    error InvalidNonce();
    error ExecutionFailed();

    // ============ CONSTRUCTOR ============

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(NAME)),
                keccak256(bytes(VERSION)),
                block.chainid,
                address(this)
            )
        );
    }

    // ============ EXTERNAL FUNCTIONS ============

    /**
     * @notice Execute a meta-transaction
     * @param request The forward request data
     * @param signature EIP-712 signature from the original sender
     * @return success Whether the call succeeded
     * @return returnData Data returned from the call
     */
    function execute(ForwardRequest calldata request, bytes calldata signature)
        external
        payable
        returns (bool success, bytes memory returnData)
    {
        // Verify deadline
        if (block.timestamp > request.deadline) {
            revert ExpiredRequest();
        }

        // Verify nonce
        if (request.nonce != nonces(request.from)) {
            revert InvalidNonce();
        }

        // Verify signature
        if (!_verify(request, signature)) {
            revert InvalidSignature();
        }

        // Consume nonce
        _useNonce(request.from);

        // Execute the call with original sender appended to data
        // Target contract can use _msgSender() from ERC2771Context to get original sender
        (success, returnData) = request.to.call{gas: request.gas, value: request.value}(
            abi.encodePacked(request.data, request.from)
        );

        emit Forwarded(
            request.from,
            request.to,
            request.value,
            request.gas,
            success,
            returnData
        );

        // Note: We don't revert on failure to allow the relayer to handle it
        // The caller can check the success boolean
    }

    /**
     * @notice Execute multiple meta-transactions in a batch
     * @param requests Array of forward requests
     * @param signatures Array of signatures
     * @return successes Array of success booleans for each request
     * @return results Array of return data for each request
     */
    function executeBatch(
        ForwardRequest[] calldata requests,
        bytes[] calldata signatures
    ) 
        external 
        payable 
        returns (bool[] memory successes, bytes[] memory results) 
    {
        require(requests.length == signatures.length, "Length mismatch");
        
        successes = new bool[](requests.length);
        results = new bytes[](requests.length);

        for (uint256 i = 0; i < requests.length; i++) {
            (successes[i], results[i]) = _executeRequest(requests[i], signatures[i]);
        }
    }

    /**
     * @notice Verify a forward request signature without executing
     * @param request The forward request
     * @param signature The signature to verify
     * @return True if valid
     */
    function verify(ForwardRequest calldata request, bytes calldata signature)
        external
        view
        returns (bool)
    {
        return _verify(request, signature);
    }

    /**
     * @notice Get the hash of a forward request (for signing)
     * @param request The forward request
     * @return The EIP-712 typed data hash
     */
    function getRequestHash(ForwardRequest calldata request)
        external
        view
        returns (bytes32)
    {
        return _hashTypedData(request);
    }

    /**
     * @notice Get current nonce for an address
     * @param account The address to query
     * @return The current nonce
     */
    function getNonce(address account) external view returns (uint256) {
        return nonces(account);
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @dev Execute a single request
     */
    function _executeRequest(
        ForwardRequest calldata request,
        bytes calldata signature
    ) internal returns (bool success, bytes memory returnData) {
        // Verify deadline
        if (block.timestamp > request.deadline) {
            return (false, bytes("Expired"));
        }

        // Verify nonce
        if (request.nonce != nonces(request.from)) {
            return (false, bytes("Invalid nonce"));
        }

        // Verify signature
        if (!_verify(request, signature)) {
            return (false, bytes("Invalid signature"));
        }

        // Consume nonce
        _useNonce(request.from);

        // Execute
        (success, returnData) = request.to.call{gas: request.gas, value: request.value}(
            abi.encodePacked(request.data, request.from)
        );

        emit Forwarded(
            request.from,
            request.to,
            request.value,
            request.gas,
            success,
            returnData
        );
    }

    /**
     * @dev Verify signature
     */
    function _verify(ForwardRequest calldata request, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        bytes32 digest = _hashTypedData(request);
        address signer = digest.recover(signature);
        return signer == request.from;
    }

    /**
     * @dev Compute EIP-712 typed data hash
     */
    function _hashTypedData(ForwardRequest calldata request)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                FORWARD_REQUEST_TYPEHASH,
                request.from,
                request.to,
                request.value,
                request.gas,
                request.nonce,
                request.deadline,
                keccak256(request.data)
            )
        );

        return keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
    }
}
