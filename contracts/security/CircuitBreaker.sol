// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title CircuitBreaker
 * @notice Emergency stop mechanism for smart contracts
 * @dev Implements multiple levels of pausing and rate limiting
 * 
 * Circuit Breaker Pattern:
 * ┌─────────────────────────────────────────────────────────────┐
 * │                    CIRCUIT STATES                           │
 * ├─────────────────────────────────────────────────────────────┤
 * │                                                              │
 * │  CLOSED (Normal Operation)                                   │
 * │    │                                                         │
 * │    │ Anomaly detected (too many failures, attack, etc.)     │
 * │    ▼                                                         │
 * │  OPEN (Emergency Stop)                                       │
 * │    │                                                         │
 * │    │ Cooldown period or manual reset                        │
 * │    ▼                                                         │
 * │  HALF-OPEN (Testing)                                         │
 * │    │                                                         │
 * │    │ Success: Close circuit                                 │
 * │    │ Failure: Re-open circuit                               │
 * │    ▼                                                         │
 * │  CLOSED (Resume normal)                                      │
 * │                                                              │
 * └─────────────────────────────────────────────────────────────┘
 */
contract CircuitBreaker is Ownable, AccessControl {

    // ═══════════════════════════════════════════════════════════════════════
    //                              ROLES
    // ═══════════════════════════════════════════════════════════════════════

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event CircuitOpened(address indexed triggeredBy, string reason);
    event CircuitClosed(address indexed closedBy);
    event CircuitHalfOpened(address indexed triggeredBy);
    event FeaturePaused(bytes32 indexed feature, address indexed pausedBy);
    event FeatureUnpaused(bytes32 indexed feature, address indexed unpausedBy);
    event EmergencyWithdrawal(address indexed to, uint256 amount);
    event ThresholdUpdated(string name, uint256 oldValue, uint256 newValue);

    // ═══════════════════════════════════════════════════════════════════════
    //                              ENUMS
    // ═══════════════════════════════════════════════════════════════════════

    enum CircuitState {
        CLOSED,     // Normal operation
        OPEN,       // Emergency stop
        HALF_OPEN   // Testing mode
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Current state of the circuit breaker
    CircuitState public state;

    /// @notice Timestamp when circuit was last opened
    uint256 public lastOpenTime;

    /// @notice Cooldown before circuit can be tested
    uint256 public cooldownPeriod = 1 hours;

    /// @notice Maximum operations in half-open state before fully closing
    uint256 public testOperationsRequired = 5;

    /// @notice Current test operations count
    uint256 public testOperationsCount;

    /// @notice Individual feature pause states
    mapping(bytes32 => bool) public featurePaused;

    /// @notice Failure count per timeframe (for auto-trip)
    mapping(uint256 => uint256) public failureCount;

    /// @notice Threshold for auto-opening circuit
    uint256 public failureThreshold = 10;

    /// @notice Timeframe for counting failures (in seconds)
    uint256 public failureTimeframe = 300; // 5 minutes

    /// @notice Rate limits per address
    mapping(address => RateLimit) public rateLimits;

    struct RateLimit {
        uint256 count;
        uint256 resetTime;
    }

    /// @notice Global rate limit per address per period
    uint256 public rateLimit = 100;
    uint256 public rateLimitPeriod = 1 hours;

    // ═══════════════════════════════════════════════════════════════════════
    //                             MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Require circuit to be closed or half-open
     */
    modifier whenCircuitClosed() {
        require(state != CircuitState.OPEN, "Circuit is open");
        _;
    }

    /**
     * @notice Require circuit to be fully closed
     */
    modifier whenFullyClosed() {
        require(state == CircuitState.CLOSED, "Circuit not fully closed");
        _;
    }

    /**
     * @notice Require specific feature to be unpaused
     */
    modifier whenFeatureActive(bytes32 feature) {
        require(!featurePaused[feature], "Feature is paused");
        _;
    }

    /**
     * @notice Apply rate limiting
     */
    modifier rateImited() {
        RateLimit storage limit = rateLimits[msg.sender];
        
        if (block.timestamp >= limit.resetTime) {
            limit.count = 1;
            limit.resetTime = block.timestamp + rateLimitPeriod;
        } else {
            require(limit.count < rateLimit, "Rate limit exceeded");
            limit.count++;
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(address _owner) Ownable(_owner) {
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(GUARDIAN_ROLE, _owner);
        _grantRole(OPERATOR_ROLE, _owner);
        state = CircuitState.CLOSED;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        CIRCUIT MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Open the circuit (emergency stop)
     * @param reason Human-readable reason for the pause
     */
    function openCircuit(string calldata reason) external onlyRole(GUARDIAN_ROLE) {
        state = CircuitState.OPEN;
        lastOpenTime = block.timestamp;
        testOperationsCount = 0;
        emit CircuitOpened(msg.sender, reason);
    }

    /**
     * @notice Attempt to half-open the circuit for testing
     */
    function halfOpenCircuit() external onlyRole(GUARDIAN_ROLE) {
        require(state == CircuitState.OPEN, "Circuit not open");
        require(
            block.timestamp >= lastOpenTime + cooldownPeriod,
            "Cooldown not complete"
        );
        
        state = CircuitState.HALF_OPEN;
        testOperationsCount = 0;
        emit CircuitHalfOpened(msg.sender);
    }

    /**
     * @notice Close the circuit (resume normal operation)
     */
    function closeCircuit() external onlyRole(GUARDIAN_ROLE) {
        state = CircuitState.CLOSED;
        testOperationsCount = 0;
        emit CircuitClosed(msg.sender);
    }

    /**
     * @notice Record a successful operation in half-open state
     * @dev Call this after each successful operation
     */
    function recordSuccess() external onlyRole(OPERATOR_ROLE) {
        if (state == CircuitState.HALF_OPEN) {
            testOperationsCount++;
            
            if (testOperationsCount >= testOperationsRequired) {
                state = CircuitState.CLOSED;
                emit CircuitClosed(address(this));
            }
        }
    }

    /**
     * @notice Record a failure (may auto-open circuit)
     */
    function recordFailure() external onlyRole(OPERATOR_ROLE) {
        // If in half-open, go back to open
        if (state == CircuitState.HALF_OPEN) {
            state = CircuitState.OPEN;
            lastOpenTime = block.timestamp;
            emit CircuitOpened(address(this), "Failure during test");
            return;
        }

        // Track failures for auto-trip
        uint256 currentPeriod = block.timestamp / failureTimeframe;
        failureCount[currentPeriod]++;

        if (failureCount[currentPeriod] >= failureThreshold) {
            state = CircuitState.OPEN;
            lastOpenTime = block.timestamp;
            emit CircuitOpened(address(this), "Auto-trip: failure threshold exceeded");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        FEATURE MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    // Common feature identifiers
    bytes32 public constant FEATURE_BATCH = keccak256("BATCH_EXECUTION");
    bytes32 public constant FEATURE_META_TX = keccak256("META_TRANSACTIONS");
    bytes32 public constant FEATURE_SPONSORSHIP = keccak256("GAS_SPONSORSHIP");
    bytes32 public constant FEATURE_DEPOSITS = keccak256("DEPOSITS");
    bytes32 public constant FEATURE_WITHDRAWALS = keccak256("WITHDRAWALS");

    /**
     * @notice Pause a specific feature
     */
    function pauseFeature(bytes32 feature) external onlyRole(GUARDIAN_ROLE) {
        featurePaused[feature] = true;
        emit FeaturePaused(feature, msg.sender);
    }

    /**
     * @notice Unpause a specific feature
     */
    function unpauseFeature(bytes32 feature) external onlyRole(GUARDIAN_ROLE) {
        featurePaused[feature] = false;
        emit FeatureUnpaused(feature, msg.sender);
    }

    /**
     * @notice Check if a feature is active
     */
    function isFeatureActive(bytes32 feature) external view returns (bool) {
        return !featurePaused[feature] && state != CircuitState.OPEN;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        THRESHOLD MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Update cooldown period
     */
    function setCooldownPeriod(uint256 newPeriod) external onlyOwner {
        emit ThresholdUpdated("cooldownPeriod", cooldownPeriod, newPeriod);
        cooldownPeriod = newPeriod;
    }

    /**
     * @notice Update failure threshold
     */
    function setFailureThreshold(uint256 newThreshold) external onlyOwner {
        emit ThresholdUpdated("failureThreshold", failureThreshold, newThreshold);
        failureThreshold = newThreshold;
    }

    /**
     * @notice Update rate limit
     */
    function setRateLimit(uint256 newLimit, uint256 newPeriod) external onlyOwner {
        emit ThresholdUpdated("rateLimit", rateLimit, newLimit);
        emit ThresholdUpdated("rateLimitPeriod", rateLimitPeriod, newPeriod);
        rateLimit = newLimit;
        rateLimitPeriod = newPeriod;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        EMERGENCY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Emergency withdraw all ETH
     * @dev Only callable when circuit is open
     */
    function emergencyWithdrawETH(address payable to) external onlyOwner {
        require(state == CircuitState.OPEN, "Circuit must be open");
        uint256 balance = address(this).balance;
        (bool success, ) = to.call{value: balance}("");
        require(success, "Transfer failed");
        emit EmergencyWhithdrawal(to, balance);
    }

    /**
     * @notice Emergency withdraw ERC20 tokens
     */
    function emergencyWithdrawToken(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        require(state == CircuitState.OPEN, "Circuit must be open");
        (bool success, ) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(success, "Token transfer failed");
    }

    // Fix typo in event
    event EmergencyWhithdrawal(address indexed to, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════
    //                            VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get full circuit status
     */
    function getCircuitStatus() external view returns (
        CircuitState currentState,
        uint256 openedAt,
        uint256 cooldownEndsAt,
        uint256 testProgress
    ) {
        currentState = state;
        openedAt = lastOpenTime;
        cooldownEndsAt = lastOpenTime + cooldownPeriod;
        testProgress = state == CircuitState.HALF_OPEN 
            ? (testOperationsCount * 100) / testOperationsRequired 
            : 0;
    }

    /**
     * @notice Get rate limit status for an address
     */
    function getRateLimitStatus(address account) external view returns (
        uint256 used,
        uint256 limit,
        uint256 resetsAt
    ) {
        RateLimit memory rl = rateLimits[account];
        used = block.timestamp >= rl.resetTime ? 0 : rl.count;
        limit = rateLimit;
        resetsAt = rl.resetTime;
    }

    receive() external payable {}
}

/**
 * @title CircuitBreakerClient
 * @notice Mixin for contracts that use the circuit breaker
 * @dev Inherit this to add circuit breaker protection
 */
abstract contract CircuitBreakerClient {
    CircuitBreaker public circuitBreaker;

    error CircuitOpen();
    error FeaturePaused(bytes32 feature);

    modifier circuitClosed() {
        if (circuitBreaker.state() == CircuitBreaker.CircuitState.OPEN) {
            revert CircuitOpen();
        }
        _;
    }

    modifier featureActive(bytes32 feature) {
        if (!circuitBreaker.isFeatureActive(feature)) {
            revert FeaturePaused(feature);
        }
        _;
    }

    function _setCircuitBreaker(CircuitBreaker _breaker) internal {
        circuitBreaker = _breaker;
    }
}
