// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MetaTxRecipient
 * @author Web3Assam Gas Optimizer Team
 * @notice Base contract for receiving meta-transactions via EIP-2771
 * @dev Inherit from this contract to support meta-transactions
 * 
 * HOW IT WORKS:
 * When a trusted forwarder calls your contract, it appends the original
 * sender's address to the calldata. This contract extracts that address
 * so you can use _msgSender() instead of msg.sender.
 */
abstract contract MetaTxRecipient {
    
    /// @notice The trusted forwarder address
    address public immutable trustedForwarder;

    constructor(address _trustedForwarder) {
        trustedForwarder = _trustedForwarder;
    }

    /**
     * @notice Check if caller is the trusted forwarder
     */
    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == trustedForwarder;
    }

    /**
     * @notice Get the actual message sender
     * @dev If called by trusted forwarder, extract sender from calldata
     *      Otherwise, return msg.sender as usual
     */
    function _msgSender() internal view virtual returns (address sender) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            // Extract sender from last 20 bytes of msg.data
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    /**
     * @notice Get the actual message data
     * @dev If called by trusted forwarder, remove appended sender
     */
    function _msgData() internal view virtual returns (bytes calldata) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            return msg.data[:msg.data.length - 20];
        } else {
            return msg.data;
        }
    }
}
