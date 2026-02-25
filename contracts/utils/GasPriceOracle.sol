// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GasPriceOracle
 * @notice On-chain gas price tracking and recommendations
 * @dev Tracks historical gas prices and provides optimization suggestions
 * 
 * Use cases:
 * 1. Smart gas price suggestions for users
 * 2. Automatic batch timing optimization
 * 3. Gas cost predictions for planning
 * 4. MEV protection through timing recommendations
 */
contract GasPriceOracle is Ownable {

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event GasPriceUpdated(uint256 gasPrice, uint256 baseFee, uint256 timestamp);
    event ThresholdUpdated(string name, uint256 value);
    event OracleUpdated(address indexed newOracle);

    // ═══════════════════════════════════════════════════════════════════════
    //                           STRUCTURES
    // ═══════════════════════════════════════════════════════════════════════

    struct GasSnapshot {
        uint256 gasPrice;       // tx.gasprice at time of snapshot
        uint256 baseFee;        // block.basefee (EIP-1559)
        uint256 blockNumber;    // When snapshot was taken
        uint256 timestamp;      // Unix timestamp
    }

    struct GasPrediction {
        uint256 low;            // Conservative estimate
        uint256 medium;         // Standard estimate
        uint256 high;           // Fast confirmation estimate
        uint256 instant;        // Next block estimate
        uint256 confidence;     // 0-100 confidence score
    }

    struct DailyStats {
        uint256 minGas;
        uint256 maxGas;
        uint256 avgGas;
        uint256 sampleCount;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Circular buffer of gas snapshots
    GasSnapshot[256] public snapshots;
    uint256 public snapshotIndex;
    uint256 public snapshotCount;

    /// @notice Daily statistics (day => stats)
    mapping(uint256 => DailyStats) public dailyStats;

    /// @notice Hourly averages (0-23)
    mapping(uint256 => uint256) public hourlyAverages;
    mapping(uint256 => uint256) public hourlySampleCount;

    /// @notice External price feed (Chainlink, etc.)
    address public externalOracle;

    /// @notice Update frequency (in blocks)
    uint256 public updateFrequency = 10;
    uint256 public lastUpdateBlock;

    /// @notice Authorized updaters
    mapping(address => bool) public authorizedUpdaters;

    /// @notice Moving averages
    uint256 public shortTermMA;  // Last 10 samples
    uint256 public longTermMA;   // Last 100 samples
    uint256 public constant SHORT_PERIOD = 10;
    uint256 public constant LONG_PERIOD = 100;

    // ═══════════════════════════════════════════════════════════════════════
    //                            CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(address _owner) Ownable(_owner) {
        authorizedUpdaters[_owner] = true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          UPDATE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Record current gas price
     * @dev Can be called by anyone, but rate limited
     */
    function recordGasPrice() external {
        require(
            block.number >= lastUpdateBlock + updateFrequency,
            "Too soon"
        );
        
        _recordSnapshot(tx.gasprice, block.basefee);
    }

    /**
     * @notice Record gas price (authorized updater)
     */
    function updateGasPrice(uint256 gasPrice, uint256 baseFee) external {
        require(authorizedUpdaters[msg.sender], "Not authorized");
        _recordSnapshot(gasPrice, baseFee);
    }

    function _recordSnapshot(uint256 gasPrice, uint256 baseFee) internal {
        // Store snapshot
        uint256 idx = snapshotIndex;
        snapshots[idx] = GasSnapshot({
            gasPrice: gasPrice,
            baseFee: baseFee,
            blockNumber: block.number,
            timestamp: block.timestamp
        });

        snapshotIndex = (idx + 1) % 256;
        if (snapshotCount < 256) snapshotCount++;
        lastUpdateBlock = block.number;

        // Update moving averages
        _updateMovingAverages(gasPrice);

        // Update hourly stats
        uint256 hour = (block.timestamp / 1 hours) % 24;
        uint256 oldCount = hourlySampleCount[hour];
        uint256 oldAvg = hourlyAverages[hour];
        hourlySampleCount[hour] = oldCount + 1;
        hourlyAverages[hour] = (oldAvg * oldCount + gasPrice) / (oldCount + 1);

        // Update daily stats
        uint256 day = block.timestamp / 1 days;
        DailyStats storage stats = dailyStats[day];
        if (stats.sampleCount == 0) {
            stats.minGas = gasPrice;
            stats.maxGas = gasPrice;
            stats.avgGas = gasPrice;
        } else {
            if (gasPrice < stats.minGas) stats.minGas = gasPrice;
            if (gasPrice > stats.maxGas) stats.maxGas = gasPrice;
            stats.avgGas = (stats.avgGas * stats.sampleCount + gasPrice) / (stats.sampleCount + 1);
        }
        stats.sampleCount++;

        emit GasPriceUpdated(gasPrice, baseFee, block.timestamp);
    }

    function _updateMovingAverages(uint256 newPrice) internal {
        // Simple exponential moving average
        if (shortTermMA == 0) {
            shortTermMA = newPrice;
            longTermMA = newPrice;
        } else {
            // EMA formula: EMA = (Price - EMA_prev) * k + EMA_prev
            // where k = 2 / (N + 1)
            shortTermMA = (newPrice * 2 + shortTermMA * (SHORT_PERIOD - 1)) / (SHORT_PERIOD + 1);
            longTermMA = (newPrice * 2 + longTermMA * (LONG_PERIOD - 1)) / (LONG_PERIOD + 1);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get current gas price from block
     */
    function getCurrentGasPrice() external view returns (uint256) {
        return block.basefee;
    }

    /**
     * @notice Get the latest recorded snapshot
     */
    function getLatestSnapshot() external view returns (GasSnapshot memory) {
        if (snapshotCount == 0) {
            return GasSnapshot(0, 0, 0, 0);
        }
        uint256 idx = snapshotIndex == 0 ? 255 : snapshotIndex - 1;
        return snapshots[idx];
    }

    /**
     * @notice Get gas price predictions
     */
    function getPredictions() external view returns (GasPrediction memory) {
        if (snapshotCount == 0) {
            return GasPrediction(0, 0, 0, 0, 0);
        }

        // Use moving averages and recent data for predictions
        uint256 latest = snapshots[snapshotCount == 256 ? 255 : snapshotIndex - 1].gasPrice;
        
        // Calculate percentiles from recent samples
        uint256 low = longTermMA * 80 / 100;      // 20% below long-term average
        uint256 medium = shortTermMA;              // Short-term average
        uint256 high = shortTermMA * 120 / 100;   // 20% above short-term average
        uint256 instant = latest * 110 / 100;     // 10% above latest

        // Confidence based on sample count
        uint256 confidence = snapshotCount >= 100 ? 90 : (snapshotCount * 90 / 100);

        return GasPrediction({
            low: low,
            medium: medium,
            high: high,
            instant: instant,
            confidence: confidence
        });
    }

    /**
     * @notice Get best time to transact (hour with lowest average)
     */
    function getBestTransactionTime() external view returns (
        uint256 bestHour,
        uint256 expectedGasPrice,
        uint256 worstHour,
        uint256 peakGasPrice
    ) {
        bestHour = 0;
        expectedGasPrice = type(uint256).max;
        worstHour = 0;
        peakGasPrice = 0;

        for (uint256 h = 0; h < 24; h++) {
            uint256 avg = hourlyAverages[h];
            if (avg > 0 && avg < expectedGasPrice) {
                expectedGasPrice = avg;
                bestHour = h;
            }
            if (avg > peakGasPrice) {
                peakGasPrice = avg;
                worstHour = h;
            }
        }
    }

    /**
     * @notice Estimate cost for a transaction
     */
    function estimateCost(uint256 gasLimit) external view returns (
        uint256 lowCost,
        uint256 mediumCost,
        uint256 highCost
    ) {
        GasPrediction memory pred = this.getPredictions();
        lowCost = gasLimit * pred.low;
        mediumCost = gasLimit * pred.medium;
        highCost = gasLimit * pred.high;
    }

    /**
     * @notice Check if current gas price is favorable
     * @return isFavorable True if current price is below short-term average
     * @return savingsPercent Percentage savings vs average (can be negative)
     */
    function isGasPriceFavorable() external view returns (
        bool isFavorable,
        int256 savingsPercent
    ) {
        uint256 current = block.basefee;
        if (shortTermMA == 0) {
            return (true, 0);
        }

        isFavorable = current < shortTermMA;
        
        if (current <= shortTermMA) {
            savingsPercent = int256((shortTermMA - current) * 100 / shortTermMA);
        } else {
            savingsPercent = -int256((current - shortTermMA) * 100 / shortTermMA);
        }
    }

    /**
     * @notice Get trend direction
     * @return direction 1 = increasing, -1 = decreasing, 0 = stable
     */
    function getTrend() external view returns (int8 direction) {
        if (shortTermMA > longTermMA * 105 / 100) {
            return 1; // Increasing
        } else if (shortTermMA < longTermMA * 95 / 100) {
            return -1; // Decreasing
        }
        return 0; // Stable
    }

    /**
     * @notice Get historical data for a day
     */
    function getDailyHistory(uint256 daysAgo) external view returns (DailyStats memory) {
        uint256 day = (block.timestamp / 1 days) - daysAgo;
        return dailyStats[day];
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function setUpdateFrequency(uint256 blocks) external onlyOwner {
        updateFrequency = blocks;
        emit ThresholdUpdated("updateFrequency", blocks);
    }

    function setAuthorizedUpdater(address updater, bool authorized) external onlyOwner {
        authorizedUpdaters[updater] = authorized;
    }

    function setExternalOracle(address oracle) external onlyOwner {
        externalOracle = oracle;
        emit OracleUpdated(oracle);
    }
}

/**
 * @title GasOptimizationSuggester
 * @notice Uses oracle data to suggest when to batch vs individual transactions
 */
contract GasOptimizationSuggester {
    GasPriceOracle public oracle;

    constructor(GasPriceOracle _oracle) {
        oracle = _oracle;
    }

    /**
     * @notice Should user batch their transactions?
     * @param numTransactions Number of pending transactions
     * @param urgency 0 = not urgent, 1 = moderate, 2 = very urgent
     */
    function shouldBatch(
        uint256 numTransactions,
        uint8 urgency
    ) external view returns (
        bool batch,
        string memory reason,
        uint256 estimatedSavings
    ) {
        // Always batch if 3+ transactions
        if (numTransactions >= 3) {
            uint256 savings = (numTransactions - 1) * 21000 * block.basefee;
            return (true, "Multiple transactions benefit from batching", savings);
        }

        // Check if gas price is favorable
        (bool favorable, int256 savingsPercent) = oracle.isGasPriceFavorable();

        // If urgent and not favorable, still recommend batching
        if (urgency >= 2 && !favorable) {
            return (true, "High urgency - batching reduces costs despite high gas", 
                    21000 * block.basefee);
        }

        // If favorable and not urgent, maybe wait for more transactions
        if (favorable && urgency == 0 && numTransactions < 3) {
            return (false, "Gas is low - consider waiting to batch more transactions", 0);
        }

        // Default: batch if 2+ transactions
        if (numTransactions >= 2) {
            return (true, "Batching 2 transactions saves base cost", 21000 * block.basefee);
        }

        return (false, "Single transaction - batching not beneficial", 0);
    }

    /**
     * @notice When should user execute their batch?
     */
    function whenToExecute(uint256 gasLimit) external view returns (
        bool executeNow,
        uint256 suggestedHour,
        uint256 estimatedSavings
    ) {
        (bool favorable, int256 savingsPercent) = oracle.isGasPriceFavorable();
        
        if (favorable && savingsPercent >= 10) {
            return (true, 0, uint256(savingsPercent) * gasLimit * block.basefee / 100);
        }

        (uint256 bestHour, uint256 expectedGas,,) = oracle.getBestTransactionTime();
        
        uint256 currentSavings = 0;
        if (block.basefee > expectedGas) {
            currentSavings = (block.basefee - expectedGas) * gasLimit;
        }

        return (false, bestHour, currentSavings);
    }
}
