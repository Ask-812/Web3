// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title GaslessToken
 * @author Web3Assam Gas Optimizer Team
 * @notice ERC20 token with meta-transaction support for gasless transfers
 * @dev Demonstrates how ERC20 tokens can integrate with our gas optimizer
 * 
 * FEATURES:
 * - Standard ERC20 functionality
 * - Meta-transaction support via trusted forwarder
 * - Gasless transfers for token holders
 * - Batch transfer capability
 */
contract GaslessToken is ERC20 {
    
    // ============ STATE VARIABLES ============
    
    address public owner;
    address public immutable trustedForwarder;
    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 10**18; // 1 million tokens
    
    // ============ EVENTS ============
    
    event BatchTransfer(
        address indexed from,
        address[] recipients,
        uint256[] amounts
    );

    // ============ MODIFIERS ============
    
    modifier onlyOwner() {
        require(_msgSender() == owner, "Not owner");
        _;
    }

    // ============ CONSTRUCTOR ============
    
    constructor(address _trustedForwarder) 
        ERC20("GaslessToken", "GLT") 
    {
        trustedForwarder = _trustedForwarder;
        owner = msg.sender;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    // ============ EXTERNAL FUNCTIONS ============

    /**
     * @notice Check if an address is the trusted forwarder
     */
    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == trustedForwarder;
    }

    /**
     * @notice Transfer tokens to multiple recipients in one transaction
     * @dev Great for airdrops and batch payments
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts to send
     */
    function batchTransfer(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external {
        require(recipients.length == amounts.length, "Array length mismatch");
        
        address sender = _msgSender();
        
        for (uint256 i = 0; i < recipients.length; i++) {
            _transfer(sender, recipients[i], amounts[i]);
        }

        emit BatchTransfer(sender, recipients, amounts);
    }

    /**
     * @notice Mint new tokens (owner only)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from caller's balance
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    // ============ OVERRIDES ============

    /**
     * @notice Override _msgSender to support meta-transactions via EIP-2771
     */
    function _msgSender() internal view override returns (address sender) {
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
     * @notice Override _msgData to support meta-transactions
     */
    function _msgData() internal view override returns (bytes calldata) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            return msg.data[:msg.data.length - 20];
        } else {
            return msg.data;
        }
    }
}
