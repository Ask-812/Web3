// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "./EntryPoint.sol";

/**
 * @title SimpleAccount
 * @notice EIP-4337 compatible smart contract wallet
 * @dev Demonstrates basic account abstraction features:
 *      - Owner-based validation
 *      - Batched execution
 *      - ETH receiving
 * 
 * This replaces traditional EOA wallets with programmable accounts
 */
contract SimpleAccount is Initializable {
    using ECDSA for bytes32;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event SimpleAccountInitialized(address indexed entryPoint, address indexed owner);
    event ExecutionSuccess(address indexed target, uint256 value, bytes data);
    event ExecutionFailure(address indexed target, uint256 value, bytes data);

    // ═══════════════════════════════════════════════════════════════════════
    //                           STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The owner of this account (can sign UserOperations)
    address public owner;

    /// @notice The EntryPoint this account trusts
    SimpleEntryPoint public entryPoint;

    /// @notice Nonce for meta-transactions (separate from EntryPoint nonce)
    uint256 public metaNonce;

    // ═══════════════════════════════════════════════════════════════════════
    //                             MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyOwner() {
        require(msg.sender == owner || msg.sender == address(this), "Not owner");
        _;
    }

    modifier onlyEntryPointOrOwner() {
        require(
            msg.sender == address(entryPoint) || 
            msg.sender == owner || 
            msg.sender == address(this),
            "Not authorized"
        );
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Initialize the account
    /// @param _entryPoint The entry point to trust
    /// @param _owner The initial owner
    function initialize(SimpleEntryPoint _entryPoint, address _owner) public initializer {
        require(address(_entryPoint) != address(0), "Invalid entry point");
        require(_owner != address(0), "Invalid owner");
        
        entryPoint = _entryPoint;
        owner = _owner;
        
        emit SimpleAccountInitialized(address(_entryPoint), _owner);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        EIP-4337 VALIDATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Validate a UserOperation
     * @dev Called by the EntryPoint to validate signatures
     * @param userOp The UserOperation to validate
     * @param userOpHash Hash of the UserOperation
     * @param missingAccountFunds Funds to send to EntryPoint if needed
     * @return validationData 0 if valid, 1 if invalid
     */
    function validateUserOp(
        SimpleEntryPoint.UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData) {
        require(msg.sender == address(entryPoint), "Only entry point");

        // Verify the signature
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash)
        );
        address signer = ethSignedHash.recover(userOp.signature);
        
        if (signer != owner) {
            return 1; // Invalid signature
        }

        // Pay prefund
        if (missingAccountFunds > 0) {
            (bool success, ) = payable(address(entryPoint)).call{value: missingAccountFunds}("");
            require(success, "Prefund failed");
        }

        return 0; // Valid
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            EXECUTION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Execute a call from this account
     * @param target Target contract
     * @param value ETH value to send
     * @param data Calldata
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyEntryPointOrOwner returns (bytes memory) {
        (bool success, bytes memory result) = target.call{value: value}(data);
        
        if (success) {
            emit ExecutionSuccess(target, value, data);
        } else {
            emit ExecutionFailure(target, value, data);
            // Bubble up the revert
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        
        return result;
    }

    /**
     * @notice Execute a batch of calls
     * @param targets Array of target contracts
     * @param values Array of ETH values
     * @param datas Array of calldatas
     */
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external onlyEntryPointOrOwner returns (bytes[] memory results) {
        require(
            targets.length == values.length && values.length == datas.length,
            "Length mismatch"
        );

        results = new bytes[](targets.length);

        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, bytes memory result) = targets[i].call{value: values[i]}(datas[i]);
            
            if (!success) {
                // Bubble up revert
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            
            results[i] = result;
            emit ExecutionSuccess(targets[i], values[i], datas[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          OWNER MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Transfer ownership
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        owner = newOwner;
    }

    /**
     * @notice Update entry point
     * @param newEntryPoint New entry point address
     */
    function updateEntryPoint(SimpleEntryPoint newEntryPoint) external onlyOwner {
        require(address(newEntryPoint) != address(0), "Invalid entry point");
        entryPoint = newEntryPoint;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get deposit info in EntryPoint
     */
    function getDeposit() public view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /**
     * @notice Deposit more funds to EntryPoint
     */
    function addDeposit() public payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /**
     * @notice Withdraw deposit from EntryPoint
     */
    function withdrawDepositTo(address payable recipient, uint256 amount) public onlyOwner {
        entryPoint.withdrawTo(recipient, amount);
    }

    /**
     * @notice Check if an address is authorized
     */
    function isAuthorized(address account) public view returns (bool) {
        return account == owner || account == address(entryPoint);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              RECEIVE
    // ═══════════════════════════════════════════════════════════════════════

    receive() external payable {}
}

/**
 * @title SimpleAccountFactory
 * @notice Factory for deploying SimpleAccount instances
 * @dev Uses CREATE2 for deterministic addresses
 */
contract SimpleAccountFactory {
    SimpleEntryPoint public immutable entryPoint;
    
    event AccountCreated(address indexed account, address indexed owner);

    constructor(SimpleEntryPoint _entryPoint) {
        entryPoint = _entryPoint;
    }

    /**
     * @notice Create a new account
     * @param owner The owner of the new account
     * @param salt Salt for CREATE2
     */
    function createAccount(
        address owner,
        uint256 salt
    ) public returns (SimpleAccount account) {
        address expectedAddress = getAccountAddress(owner, salt);
        
        // If already deployed, return existing
        if (expectedAddress.code.length > 0) {
            return SimpleAccount(payable(expectedAddress));
        }

        // Deploy new account
        account = new SimpleAccount{salt: bytes32(salt)}();
        account.initialize(entryPoint, owner);
        
        emit AccountCreated(address(account), owner);
    }

    /**
     * @notice Get the counterfactual address of an account
     */
    function getAccountAddress(address owner, uint256 salt) public view returns (address) {
        bytes32 bytecodeHash = keccak256(type(SimpleAccount).creationCode);
        
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            bytes32(salt),
            bytecodeHash
        )))));
    }
}
