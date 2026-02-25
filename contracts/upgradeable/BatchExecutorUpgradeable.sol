// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title BatchExecutorV2Upgradeable
 * @notice Upgradeable version of BatchExecutor using UUPS proxy pattern
 * @dev Allows for seamless upgrades without changing the contract address
 * 
 * Proxy Pattern Explained:
 * ┌─────────────────────────────────────────────────────────────────┐
 * │                     UUPS PROXY PATTERN                          │
 * ├─────────────────────────────────────────────────────────────────┤
 * │                                                                  │
 * │   User Call                                                      │
 * │      │                                                           │
 * │      ▼                                                           │
 * │   ┌──────────────────┐                                          │
 * │   │  Proxy Contract  │  ← Stores: state variables               │
 * │   │  (constant addr) │            + implementation address      │
 * │   └────────┬─────────┘                                          │
 * │            │ delegatecall                                        │
 * │            ▼                                                     │
 * │   ┌──────────────────┐                                          │
 * │   │  Implementation  │  ← Contains: all logic                   │
 * │   │  (can change)    │            (no state stored here)        │
 * │   └──────────────────┘                                          │
 * │                                                                  │
 * │   To upgrade: deploy new implementation, call upgradeToAndCall  │
 * │   State is preserved because it lives in the proxy              │
 * │                                                                  │
 * └─────────────────────────────────────────────────────────────────┘
 */
contract BatchExecutorV2Upgradeable is 
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable 
{
    using ECDSA for bytes32;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event BatchExecuted(
        address indexed executor,
        address indexed sender,
        uint256 callCount,
        uint256 gasUsed,
        uint256 indexed batchId
    );
    
    event CallExecuted(
        uint256 indexed index,
        address indexed target,
        bool success,
        bytes returnData
    );
    
    event RelayerUpdated(address indexed relayer, bool authorized);
    event GasSponsorUpdated(address indexed oldSponsor, address indexed newSponsor);
    event ContractUpgraded(address indexed oldImpl, address indexed newImpl);

    // ═══════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error EmptyBatch();
    error CallFailed(uint256 index, bytes returnData);
    error InvalidSignature();
    error ExpiredDeadline();
    error InvalidNonce();
    error UnauthorizedRelayer();
    error NotAuthorizedToUpgrade();

    // ═══════════════════════════════════════════════════════════════════════
    //                           STRUCTURES
    // ═══════════════════════════════════════════════════════════════════════

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    struct BatchRequest {
        address from;
        Call[] calls;
        uint256 nonce;
        uint256 deadline;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    bytes32 public constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    bytes32 public constant BATCH_TYPEHASH = keccak256(
        "BatchExecution(address from,bytes32 callsHash,uint256 nonce,uint256 deadline)"
    );

    // ═══════════════════════════════════════════════════════════════════════
    //                           STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:storage-location erc7201:gasoptimizer.batchexecutor
    /// @dev Using namespaced storage for upgradeability safety
    
    /// @notice EIP-712 domain separator
    bytes32 public DOMAIN_SEPARATOR;

    /// @notice Nonces for replay protection
    mapping(address => uint256) public nonces;

    /// @notice Authorized relayers
    mapping(address => bool) public authorizedRelayers;

    /// @notice Whether relayer whitelist is enabled
    bool public relayerWhitelistEnabled;

    /// @notice Gas sponsor contract
    address public gasSponsor;

    /// @notice Statistics
    uint256 public totalGasSaved;
    uint256 public totalBatchesExecuted;

    /// @notice Storage gap for future upgrades
    uint256[50] private __gap;

    // ═══════════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract (replaces constructor)
     * @param _owner Initial owner address
     */
    function initialize(address _owner) public initializer {
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256("GasOptimizer"),
            keccak256("2"),
            block.chainid,
            address(this)
        ));
    }

    /**
     * @notice Reinitialize for upgrades (bump version number each upgrade)
     */
    function reinitialize() public reinitializer(2) {
        // Add any new initialization logic for v2
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Execute a batch of calls
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
        uint256 estimatedSavings = (calls.length - 1) * 21000;
        totalGasSaved += estimatedSavings;

        emit BatchExecuted(msg.sender, msg.sender, calls.length, gasUsed, totalBatchesExecuted);
    }

    /**
     * @notice Execute a batch via meta-transaction
     * @param request The batch request signed by user
     * @param signature EIP-712 signature
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
        // Validate relayer
        if (relayerWhitelistEnabled && !authorizedRelayers[msg.sender]) {
            revert UnauthorizedRelayer();
        }

        // Check deadline
        if (block.timestamp > request.deadline) {
            revert ExpiredDeadline();
        }

        // Check nonce
        if (request.nonce != nonces[request.from]) {
            revert InvalidNonce();
        }

        // Verify signature
        bytes32 callsHash = _hashCalls(request.calls);
        bytes32 structHash = keccak256(abi.encode(
            BATCH_TYPEHASH,
            request.from,
            callsHash,
            request.nonce,
            request.deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            DOMAIN_SEPARATOR,
            structHash
        ));

        address signer = digest.recover(signature);
        if (signer != request.from) {
            revert InvalidSignature();
        }

        // Increment nonce
        nonces[request.from]++;

        // Execute
        uint256 gasStart = gasleft();
        results = _executeCalls(request.calls, request.from);
        uint256 gasUsed = gasStart - gasleft();

        totalBatchesExecuted++;

        emit BatchExecuted(msg.sender, request.from, request.calls.length, gasUsed, totalBatchesExecuted);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function _executeCalls(Call[] calldata calls, address sender)
        internal
        returns (bytes[] memory results)
    {
        results = new bytes[](calls.length);

        for (uint256 i = 0; i < calls.length; i++) {
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

    function _hashCalls(Call[] calldata calls) internal pure returns (bytes32) {
        bytes memory encoded;
        for (uint256 i = 0; i < calls.length; i++) {
            encoded = abi.encodePacked(
                encoded,
                calls[i].target,
                calls[i].value,
                keccak256(calls[i].data)
            );
        }
        return keccak256(encoded);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function setRelayer(address relayer, bool authorized) external onlyOwner {
        authorizedRelayers[relayer] = authorized;
        emit RelayerUpdated(relayer, authorized);
    }

    function setRelayerWhitelistEnabled(bool enabled) external onlyOwner {
        relayerWhitelistEnabled = enabled;
    }

    function setGasSponsor(address newSponsor) external onlyOwner {
        address old = gasSponsor;
        gasSponsor = newSponsor;
        emit GasSponsorUpdated(old, newSponsor);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         UPGRADE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Authorize upgrade to new implementation
     * @dev Required by UUPS pattern - only owner can upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        emit ContractUpgraded(address(this), newImplementation);
    }

    /**
     * @notice Get implementation version
     */
    function version() public pure virtual returns (string memory) {
        return "2.0.0";
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function getNonce(address account) external view returns (uint256) {
        return nonces[account];
    }

    function getStats() external view returns (uint256, uint256) {
        return (totalGasSaved, totalBatchesExecuted);
    }

    // Allow receiving ETH
    receive() external payable {}
}

/**
 * @title BatchExecutorV3
 * @notice Example of how to create an upgraded version
 * @dev Inherits from V2 and adds new features
 */
contract BatchExecutorV3 is BatchExecutorV2Upgradeable {
    
    // New state variables MUST be added at the end
    // NEVER remove or reorder existing variables
    
    /// @notice New feature: batch execution paused
    bool public paused;
    
    /// @notice New feature: maximum calls per batch
    uint256 public maxCallsPerBatch;

    // New error
    error ContractPaused();
    error TooManyCalls(uint256 count, uint256 max);

    // New event
    event PauseStatusChanged(bool paused);

    /// @notice Initialize V3 specific state
    function initializeV3(uint256 _maxCalls) public reinitializer(3) {
        maxCallsPerBatch = _maxCalls;
    }

    /// @notice Override version
    function version() public pure override returns (string memory) {
        return "3.0.0";
    }

    /// @notice Pause/unpause
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PauseStatusChanged(_paused);
    }

    /// @notice Set max calls
    function setMaxCallsPerBatch(uint256 _max) external onlyOwner {
        maxCallsPerBatch = _max;
    }

    // Note: To fully implement V3, you would override executeBatch and executeBatchMeta
    // to add pause checks and call limits
}
