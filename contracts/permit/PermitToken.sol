// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GaslessPermitToken
 * @notice ERC20 token with EIP-2612 permit functionality
 * @dev Allows gasless approvals via signatures
 * 
 * EIP-2612 Flow:
 * 1. User signs a permit message off-chain (no gas!)
 * 2. Anyone can submit the permit to the contract
 * 3. Contract verifies signature and sets allowance
 * 4. Now spender can transferFrom immediately
 * 
 * This eliminates the need for a separate approve() transaction!
 */
contract GaslessPermitToken is ERC20, ERC20Permit, Ownable {
    
    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════
    
    event BatchTransferExecuted(address indexed from, uint256 totalAmount, uint256 recipientCount);

    // ═══════════════════════════════════════════════════════════════════════
    //                            CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address owner
    ) 
        ERC20(name, symbol) 
        ERC20Permit(name) 
        Ownable(owner) 
    {
        _mint(owner, initialSupply);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          BATCH TRANSFERS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Transfer to multiple recipients in one transaction
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts
     */
    function batchTransfer(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external returns (bool) {
        require(recipients.length == amounts.length, "Length mismatch");
        require(recipients.length > 0, "Empty batch");

        uint256 totalAmount;
        for (uint256 i = 0; i < recipients.length; i++) {
            totalAmount += amounts[i];
            _transfer(msg.sender, recipients[i], amounts[i]);
        }

        emit BatchTransferExecuted(msg.sender, totalAmount, recipients.length);
        return true;
    }

    /**
     * @notice Batch transfer using permit (gasless approval)
     * @dev Combines permit + batchTransfer in one call
     */
    function permitAndBatchTransfer(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external {
        // First, set the allowance via permit
        permit(owner, spender, value, deadline, v, r, s);
        
        // Then execute batch transfers from owner's balance
        require(recipients.length == amounts.length, "Length mismatch");
        
        uint256 totalAmount;
        for (uint256 i = 0; i < recipients.length; i++) {
            totalAmount += amounts[i];
        }
        require(totalAmount <= value, "Amount exceeds permit");

        for (uint256 i = 0; i < recipients.length; i++) {
            _transfer(owner, recipients[i], amounts[i]);
        }

        emit BatchTransferExecuted(owner, totalAmount, recipients.length);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Mint new tokens (only owner)
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/**
 * @title PermitBatchExecutor
 * @notice Execute batched operations using permit signatures
 * @dev Combines permit approvals with batch execution
 */
contract PermitBatchExecutor {
    
    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════
    
    event PermitBatchExecuted(
        address indexed token,
        address indexed owner,
        uint256 permitValue,
        uint256 recipientCount
    );

    // ═══════════════════════════════════════════════════════════════════════
    //                            STRUCTURES
    // ═══════════════════════════════════════════════════════════════════════

    struct PermitData {
        address token;      // ERC20Permit token address
        uint256 value;      // Permit value
        uint256 deadline;   // Permit deadline
        uint8 v;            // Signature v
        bytes32 r;          // Signature r
        bytes32 s;          // Signature s
    }

    struct TransferData {
        address recipient;  // Who receives tokens
        uint256 amount;     // How much they receive
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         EXECUTION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Execute permit + multiple transfers
     * @param permitData The permit signature data
     * @param transfers Array of transfers to execute
     */
    function permitAndTransfer(
        PermitData calldata permitData,
        TransferData[] calldata transfers
    ) external {
        IERC20Permit token = IERC20Permit(permitData.token);
        
        // Execute permit (owner approves this contract)
        token.permit(
            msg.sender,
            address(this),
            permitData.value,
            permitData.deadline,
            permitData.v,
            permitData.r,
            permitData.s
        );

        // Execute transfers
        uint256 totalTransferred;
        for (uint256 i = 0; i < transfers.length; i++) {
            IERC20(permitData.token).transferFrom(
                msg.sender,
                transfers[i].recipient,
                transfers[i].amount
            );
            totalTransferred += transfers[i].amount;
        }

        require(totalTransferred <= permitData.value, "Exceeded permit");
        
        emit PermitBatchExecuted(
            permitData.token,
            msg.sender,
            permitData.value,
            transfers.length
        );
    }

    /**
     * @notice Execute multiple permits + transfers for multiple tokens
     * @param permits Array of permit data (one per token)
     * @param tokenTransfers Array of arrays (transfers per token)
     */
    function multiPermitAndTransfer(
        PermitData[] calldata permits,
        TransferData[][] calldata tokenTransfers
    ) external {
        require(permits.length == tokenTransfers.length, "Length mismatch");

        for (uint256 i = 0; i < permits.length; i++) {
            PermitData calldata permitData = permits[i];
            TransferData[] calldata transfers = tokenTransfers[i];
            
            IERC20Permit token = IERC20Permit(permitData.token);
            
            // Execute permit
            token.permit(
                msg.sender,
                address(this),
                permitData.value,
                permitData.deadline,
                permitData.v,
                permitData.r,
                permitData.s
            );

            // Execute transfers
            uint256 totalTransferred;
            for (uint256 j = 0; j < transfers.length; j++) {
                IERC20(permitData.token).transferFrom(
                    msg.sender,
                    transfers[j].recipient,
                    transfers[j].amount
                );
                totalTransferred += transfers[j].amount;
            }

            require(totalTransferred <= permitData.value, "Exceeded permit");
            
            emit PermitBatchExecuted(
                permitData.token,
                msg.sender,
                permitData.value,
                transfers.length
            );
        }
    }
}

/**
 * @title SwapWithPermit
 * @notice Example: DEX-style swap using permit
 * @dev Shows how permit enables gasless trading flows
 */
contract SwapWithPermit {
    
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    // Simple mock exchange rate (1:2 for demo)
    function getExchangeRate(address, address) public pure returns (uint256) {
        return 2; // 1 tokenIn = 2 tokenOut
    }

    /**
     * @notice Swap tokens using permit (no prior approval needed!)
     * @dev User signs permit off-chain, submits swap in one tx
     */
    function swapWithPermit(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountOut) {
        // Calculate output
        uint256 rate = getExchangeRate(tokenIn, tokenOut);
        amountOut = amountIn * rate;
        require(amountOut >= minAmountOut, "Slippage too high");

        // Use permit to approve and pull tokens in one step
        IERC20Permit(tokenIn).permit(
            msg.sender,
            address(this),
            amountIn,
            deadline,
            v,
            r,
            s
        );

        // Pull input tokens
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Send output tokens (assuming this contract has them)
        require(
            IERC20(tokenOut).balanceOf(address(this)) >= amountOut,
            "Insufficient liquidity"
        );
        IERC20(tokenOut).transfer(msg.sender, amountOut);

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }
}
