// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title SimpleEntryPoint
 * @notice Simplified EIP-4337 inspired entry point for Account Abstraction
 * @dev This is a simplified version for demonstration - production would use full EIP-4337
 * 
 * EIP-4337 Account Abstraction allows:
 * - Users to have smart contract wallets instead of EOAs
 * - Custom validation logic (multisig, social recovery, etc.)
 * - Gas payment by third parties (Paymasters)
 * - Bundling of multiple user operations
 */
contract SimpleEntryPoint is ReentrancyGuard {
    using ECDSA for bytes32;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event UserOperationEvent(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed paymaster,
        uint256 nonce,
        bool success,
        uint256 actualGasCost
    );

    event AccountDeployed(
        bytes32 indexed userOpHash,
        address indexed sender,
        address factory,
        address paymaster
    );

    event Deposited(address indexed account, uint256 totalDeposit);
    event Withdrawn(address indexed account, address withdrawAddress, uint256 amount);
    event StakeLocked(address indexed account, uint256 totalStaked, uint256 unstakeDelaySec);
    event StakeUnlocked(address indexed account, uint256 withdrawTime);
    event StakeWithdrawn(address indexed account, address withdrawAddress, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════
    //                            DATA STRUCTURES
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice User Operation structure (simplified from EIP-4337)
     * @dev Full EIP-4337 has more fields, this is streamlined for learning
     */
    struct UserOperation {
        address sender;              // Smart contract wallet address
        uint256 nonce;               // Anti-replay nonce
        bytes initCode;              // Factory + calldata to deploy wallet (if not exists)
        bytes callData;              // Actual call to execute
        uint256 callGasLimit;        // Gas for the call execution
        uint256 verificationGasLimit;// Gas for validation
        uint256 preVerificationGas;  // Extra gas for bundler overhead
        uint256 maxFeePerGas;        // Max fee per gas (EIP-1559)
        uint256 maxPriorityFeePerGas;// Max priority fee
        bytes paymasterAndData;      // Paymaster address + extra data
        bytes signature;             // Signature over the UserOp
    }

    /**
     * @notice Deposit info for accounts and paymasters
     */
    struct DepositInfo {
        uint112 deposit;
        bool staked;
        uint112 stake;
        uint32 unstakeDelaySec;
        uint48 withdrawTime;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Nonce tracking for each sender
    mapping(address => uint256) public nonceSequenceNumber;

    /// @notice Deposits for accounts and paymasters
    mapping(address => DepositInfo) public deposits;

    /// @notice Minimum stake required for paymasters
    uint256 public constant MIN_STAKE = 0.1 ether;

    /// @notice Minimum unstake delay
    uint256 public constant MIN_UNSTAKE_DELAY = 1 days;

    // ═══════════════════════════════════════════════════════════════════════
    //                           CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Handle a batch of User Operations
     * @param ops Array of UserOperations to execute
     * @param beneficiary Address to receive gas refunds
     * @dev This is the main entry point called by bundlers
     */
    function handleOps(
        UserOperation[] calldata ops,
        address payable beneficiary
    ) public nonReentrant {
        uint256 opsLen = ops.length;
        uint256[] memory collected = new uint256[](opsLen);

        for (uint256 i = 0; i < opsLen; i++) {
            uint256 gasStart = gasleft();
            bytes32 userOpHash = getUserOpHash(ops[i]);
            
            // Validate the operation
            (bool validationSuccess, address paymaster) = _validateUserOp(ops[i], userOpHash);
            require(validationSuccess, "Validation failed");

            // Execute the operation
            bool success = _executeUserOp(ops[i]);

            // Calculate gas cost
            uint256 gasUsed = gasStart - gasleft();
            uint256 actualGasCost = gasUsed * tx.gasprice;
            collected[i] = actualGasCost;

            emit UserOperationEvent(
                userOpHash,
                ops[i].sender,
                paymaster,
                ops[i].nonce,
                success,
                actualGasCost
            );
        }

        // Compensate beneficiary
        uint256 totalCollected;
        for (uint256 i = 0; i < collected.length; i++) {
            totalCollected += collected[i];
        }
        
        if (totalCollected > 0 && address(this).balance >= totalCollected) {
            (bool sent, ) = beneficiary.call{value: totalCollected}("");
            require(sent, "Failed to compensate beneficiary");
        }
    }

    /**
     * @notice Get unique hash for a UserOperation
     */
    function getUserOpHash(UserOperation calldata userOp) public view returns (bytes32) {
        return keccak256(abi.encode(
            _getUserOpDataHash(userOp),
            address(this),
            block.chainid
        ));
    }

    /**
     * @notice Get the current nonce for an account
     */
    function getNonce(address sender) public view returns (uint256) {
        return nonceSequenceNumber[sender];
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         DEPOSIT MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit ETH for an account (used for gas payments)
     */
    function depositTo(address account) public payable {
        deposits[account].deposit += uint112(msg.value);
        emit Deposited(account, deposits[account].deposit);
    }

    /**
     * @notice Get balance for an account
     */
    function balanceOf(address account) public view returns (uint256) {
        return deposits[account].deposit;
    }

    /**
     * @notice Withdraw deposit
     */
    function withdrawTo(address payable withdrawAddress, uint256 amount) public {
        DepositInfo storage info = deposits[msg.sender];
        require(info.deposit >= amount, "Insufficient deposit");
        info.deposit -= uint112(amount);
        (bool success, ) = withdrawAddress.call{value: amount}("");
        require(success, "Withdraw failed");
        emit Withdrawn(msg.sender, withdrawAddress, amount);
    }

    /**
     * @notice Add stake for a paymaster
     */
    function addStake(uint32 unstakeDelaySec) public payable {
        require(unstakeDelaySec >= MIN_UNSTAKE_DELAY, "Unstake delay too short");
        DepositInfo storage info = deposits[msg.sender];
        info.stake += uint112(msg.value);
        info.staked = true;
        info.unstakeDelaySec = unstakeDelaySec;
        emit StakeLocked(msg.sender, info.stake, unstakeDelaySec);
    }

    /**
     * @notice Start unstake process
     */
    function unlockStake() public {
        DepositInfo storage info = deposits[msg.sender];
        require(info.staked, "Not staked");
        info.withdrawTime = uint48(block.timestamp + info.unstakeDelaySec);
        emit StakeUnlocked(msg.sender, info.withdrawTime);
    }

    /**
     * @notice Withdraw stake after unstake delay
     */
    function withdrawStake(address payable withdrawAddress) public {
        DepositInfo storage info = deposits[msg.sender];
        require(info.withdrawTime > 0, "Not unlocked");
        require(info.withdrawTime <= block.timestamp, "Stake locked");
        uint256 amount = info.stake;
        info.stake = 0;
        info.staked = false;
        info.withdrawTime = 0;
        (bool success, ) = withdrawAddress.call{value: amount}("");
        require(success, "Withdraw failed");
        emit StakeWithdrawn(msg.sender, withdrawAddress, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function _getUserOpDataHash(UserOperation calldata userOp) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            userOp.sender,
            userOp.nonce,
            keccak256(userOp.initCode),
            keccak256(userOp.callData),
            userOp.callGasLimit,
            userOp.verificationGasLimit,
            userOp.preVerificationGas,
            userOp.maxFeePerGas,
            userOp.maxPriorityFeePerGas,
            keccak256(userOp.paymasterAndData)
        ));
    }

    function _validateUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash
    ) internal returns (bool, address) {
        // Deploy account if needed
        if (userOp.initCode.length > 0) {
            _deployAccount(userOp.initCode);
        }

        // Verify nonce
        require(userOp.nonce == nonceSequenceNumber[userOp.sender], "Invalid nonce");
        nonceSequenceNumber[userOp.sender]++;

        // Validate with account
        try IAccount(userOp.sender).validateUserOp(userOp, userOpHash, 0) returns (uint256 validationData) {
            if (validationData != 0) {
                return (false, address(0));
            }
        } catch {
            return (false, address(0));
        }

        // Handle paymaster if present
        address paymaster = address(0);
        if (userOp.paymasterAndData.length >= 20) {
            paymaster = address(bytes20(userOp.paymasterAndData[:20]));
            // In production, validate with paymaster here
        }

        return (true, paymaster);
    }

    function _deployAccount(bytes calldata initCode) internal {
        require(initCode.length >= 20, "Invalid initCode");
        address factory = address(bytes20(initCode[:20]));
        bytes memory factoryCalldata = initCode[20:];
        
        (bool success, ) = factory.call(factoryCalldata);
        require(success, "Account deployment failed");
    }

    function _executeUserOp(UserOperation calldata userOp) internal returns (bool) {
        if (userOp.callData.length == 0) {
            return true;
        }

        (bool success, ) = userOp.sender.call{gas: userOp.callGasLimit}(userOp.callData);
        return success;
    }

    receive() external payable {
        depositTo(msg.sender);
    }
}

/**
 * @title IAccount
 * @notice Interface for EIP-4337 compatible accounts
 */
interface IAccount {
    function validateUserOp(
        SimpleEntryPoint.UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData);
}

/**
 * @title IPaymaster
 * @notice Interface for EIP-4337 compatible paymasters
 */
interface IPaymaster {
    function validatePaymasterUserOp(
        SimpleEntryPoint.UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData);

    function postOp(
        bool success,
        bytes calldata context,
        uint256 actualGasCost
    ) external;
}
