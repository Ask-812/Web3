// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./EntryPoint.sol";

/**
 * @title VerifyingPaymaster
 * @notice EIP-4337 Paymaster that sponsors gas based on off-chain signatures
 * @dev This paymaster verifies signatures from a trusted signer before sponsoring
 * 
 * Paymaster Flow:
 * 1. User creates UserOperation
 * 2. User requests sponsorship from off-chain service
 * 3. Service validates user/action and signs approval
 * 4. User adds paymaster + signature to UserOperation
 * 5. Bundler submits operation
 * 6. EntryPoint calls paymaster to validate
 * 7. If valid, paymaster pays for gas
 * 8. After execution, paymaster.postOp() is called
 */
contract VerifyingPaymaster is Ownable {
    using ECDSA for bytes32;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event VerifyingSignerChanged(address indexed oldSigner, address indexed newSigner);
    event GasSponsored(address indexed account, uint256 actualGasCost);
    event SponsorshipPolicyUpdated(bytes32 indexed policyHash);

    // ═══════════════════════════════════════════════════════════════════════
    //                           STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The entry point this paymaster works with
    SimpleEntryPoint public immutable entryPoint;

    /// @notice Address that signs sponsorship approvals
    address public verifyingSigner;

    /// @notice Mapping of used signatures (prevents replay)
    mapping(bytes32 => bool) public usedSignatures;

    /// @notice Maximum gas this paymaster will sponsor per operation
    uint256 public maxSponsoredGas = 500_000;

    /// @notice Per-user daily sponsorship limits
    mapping(address => uint256) public dailySponsored;
    mapping(address => uint256) public lastSponsorReset;
    uint256 public maxDailyGasPerUser = 2_000_000;

    /// @notice Whitelisted contracts that can be called
    mapping(address => bool) public whitelistedTargets;
    bool public targetWhitelistEnabled;

    // ═══════════════════════════════════════════════════════════════════════
    //                            CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(
        SimpleEntryPoint _entryPoint,
        address _verifyingSigner,
        address _owner
    ) Ownable(_owner) {
        require(address(_entryPoint) != address(0), "Invalid entry point");
        require(_verifyingSigner != address(0), "Invalid signer");
        
        entryPoint = _entryPoint;
        verifyingSigner = _verifyingSigner;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        PAYMASTER VALIDATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Validate a paymaster user operation
     * @dev The paymasterAndData field contains:
     *      - First 20 bytes: paymaster address
     *      - Next 32 bytes: validUntil timestamp
     *      - Next 32 bytes: validAfter timestamp  
     *      - Remaining: signature
     */
    function validatePaymasterUserOp(
        SimpleEntryPoint.UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external view returns (bytes memory context, uint256 validationData) {
        require(msg.sender == address(entryPoint), "Only entry point");

        // Decode paymaster data
        (uint48 validUntil, uint48 validAfter, bytes memory signature) = 
            _parsePaymasterData(userOp.paymasterAndData);

        // Validate time bounds
        if (block.timestamp > validUntil || block.timestamp < validAfter) {
            return ("", _packValidationData(true, validUntil, validAfter));
        }

        // Verify sponsorship signature
        bytes32 hash = getHash(userOp, validUntil, validAfter);
        address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(hash), signature);
        
        if (signer != verifyingSigner) {
            return ("", _packValidationData(true, validUntil, validAfter));
        }

        // Check if signature was already used
        if (usedSignatures[keccak256(signature)]) {
            return ("", _packValidationData(true, validUntil, validAfter));
        }

        // Encode context for postOp
        context = abi.encode(userOp.sender, maxCost, keccak256(signature));
        return (context, _packValidationData(false, validUntil, validAfter));
    }

    /**
     * @notice Called after UserOperation execution
     */
    function postOp(
        bool success,
        bytes calldata context,
        uint256 actualGasCost
    ) external {
        require(msg.sender == address(entryPoint), "Only entry point");

        (address sender, , bytes32 signatureHash) = abi.decode(
            context, 
            (address, uint256, bytes32)
        );

        // Mark signature as used
        usedSignatures[signatureHash] = true;

        // Update daily limits
        _updateDailyUsage(sender, actualGasCost);

        emit GasSponsored(sender, actualGasCost);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            HASH FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get hash for sponsorship verification
     */
    function getHash(
        SimpleEntryPoint.UserOperation calldata userOp,
        uint48 validUntil,
        uint48 validAfter
    ) public view returns (bytes32) {
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
            block.chainid,
            address(this),
            validUntil,
            validAfter
        ));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Update the verifying signer
     */
    function setVerifyingSigner(address newSigner) external onlyOwner {
        require(newSigner != address(0), "Invalid signer");
        address old = verifyingSigner;
        verifyingSigner = newSigner;
        emit VerifyingSignerChanged(old, newSigner);
    }

    /**
     * @notice Update max sponsored gas per operation
     */
    function setMaxSponsoredGas(uint256 newMax) external onlyOwner {
        maxSponsoredGas = newMax;
    }

    /**
     * @notice Update daily limit per user
     */
    function setMaxDailyGasPerUser(uint256 newMax) external onlyOwner {
        maxDailyGasPerUser = newMax;
    }

    /**
     * @notice Whitelist a target contract
     */
    function setWhitelistedTarget(address target, bool allowed) external onlyOwner {
        whitelistedTargets[target] = allowed;
    }

    /**
     * @notice Enable/disable target whitelist
     */
    function setTargetWhitelistEnabled(bool enabled) external onlyOwner {
        targetWhitelistEnabled = enabled;
    }

    /**
     * @notice Deposit to entry point
     */
    function deposit() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /**
     * @notice Withdraw from entry point
     */
    function withdrawTo(address payable to, uint256 amount) external onlyOwner {
        entryPoint.withdrawTo(to, amount);
    }

    /**
     * @notice Add stake to entry point
     */
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /**
     * @notice Unlock stake from entry point
     */
    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    /**
     * @notice Withdraw stake from entry point
     */
    function withdrawStake(address payable to) external onlyOwner {
        entryPoint.withdrawStake(to);
    }

    /**
     * @notice Get deposit in entry point
     */
    function getDeposit() public view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function _parsePaymasterData(bytes calldata paymasterAndData) 
        internal 
        pure 
        returns (uint48 validUntil, uint48 validAfter, bytes memory signature) 
    {
        require(paymasterAndData.length >= 20 + 32 + 32, "Invalid data length");
        
        // Skip first 20 bytes (paymaster address)
        validUntil = uint48(bytes6(paymasterAndData[20:26]));
        validAfter = uint48(bytes6(paymasterAndData[26:32]));
        signature = paymasterAndData[32:];
    }

    function _packValidationData(
        bool sigFailed,
        uint48 validUntil,
        uint48 validAfter  
    ) internal pure returns (uint256) {
        return (sigFailed ? 1 : 0) | 
               (uint256(validUntil) << 160) | 
               (uint256(validAfter) << 208);
    }

    function _updateDailyUsage(address user, uint256 gasUsed) internal {
        // Reset daily counter if new day
        if (block.timestamp > lastSponsorReset[user] + 1 days) {
            dailySponsored[user] = 0;
            lastSponsorReset[user] = block.timestamp;
        }
        
        dailySponsored[user] += gasUsed;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              RECEIVE
    // ═══════════════════════════════════════════════════════════════════════

    receive() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }
}

/**
 * @title DepositPaymaster
 * @notice Simple paymaster that uses deposited balances
 * @dev Users deposit ETH, paymaster uses their balance for gas
 */
contract DepositPaymaster is Ownable {
    SimpleEntryPoint public immutable entryPoint;
    
    mapping(address => uint256) public balances;
    
    event Deposit(address indexed account, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);

    constructor(SimpleEntryPoint _entryPoint, address _owner) Ownable(_owner) {
        entryPoint = _entryPoint;
    }

    function depositFor(address account) external payable {
        balances[account] += msg.value;
        emit Deposit(account, msg.value);
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
        emit Withdraw(msg.sender, amount);
    }

    function validatePaymasterUserOp(
        SimpleEntryPoint.UserOperation calldata userOp,
        bytes32,
        uint256 maxCost
    ) external view returns (bytes memory context, uint256 validationData) {
        require(msg.sender == address(entryPoint), "Only entry point");
        require(balances[userOp.sender] >= maxCost, "Insufficient deposit");
        return (abi.encode(userOp.sender, maxCost), 0);
    }

    function postOp(
        bool,
        bytes calldata context,
        uint256 actualGasCost
    ) external {
        require(msg.sender == address(entryPoint), "Only entry point");
        (address sender, ) = abi.decode(context, (address, uint256));
        balances[sender] -= actualGasCost;
    }

    function depositToEntryPoint() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    receive() external payable {
        balances[msg.sender] += msg.value;
    }
}
