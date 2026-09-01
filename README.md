# Gas Fee Optimizer & Batch Transaction System

> A comprehensive solution for reducing Ethereum gas costs and improving user experience through transaction batching, meta-transactions, and gas sponsorship.

**Built for KRITI 2026 - Web3 Assam**

![Solidity](https://img.shields.io/badge/solidity-0.8.24-purple.svg)
![Hardhat](https://img.shields.io/badge/hardhat-2.x-yellow.svg)

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Usage](#usage)
- [Architecture](#architecture)
- [Smart Contracts](#smart-contracts)
- [Testing](#testing)
- [Gas Savings Demo](#gas-savings-demo)
- [Security](#security)
- [Limitations](#limitations)
- [Contributing](#contributing)

---

## Overview

Ethereum transactions require users to pay gas fees for every on-chain action. This creates significant friction:

- **High costs**: Each transaction costs ~21,000+ gas just for the base fee
- **Poor UX**: Multiple wallet prompts for multi-step operations
- **Onboarding barriers**: New users must acquire ETH before using dApps

This project solves these problems by implementing:

1. **Transaction Batching**: Execute multiple actions in a single transaction
2. **Meta-Transactions**: Users sign off-chain; relayers submit on-chain
3. **Gas Sponsorship**: Optional gas subsidization for users

---

## Features

### Core Features

| Feature | Description |
|---------|-------------|
| **Batch Execution** | Combine multiple contract calls into one transaction |
| **Meta-Transactions** | Gasless transactions via EIP-712 signatures |
| **Gas Sponsorship** | Full or partial gas fee subsidization |
| **Replay Protection** | Nonce-based protection against replay attacks |
| **Deadlines** | Time-limited transaction validity |
| **Relayer System** | Decentralized transaction submission |

### Technical Features

- EIP-712 typed data signing
- EIP-2771 compatible forwarder
- EIP-2612 Permit for gasless approvals
- EIP-4337 Account Abstraction (simplified)
- OpenZeppelin security standards
- Comprehensive test coverage (66 tests)
- Gas usage analytics
- TypeScript SDK for easy integration
- Node.js Relayer service

### Advanced Features

| Feature | Description |
|---------|-------------|
| **Multicall3** | Industry-standard batching contract |
| **Circuit Breaker** | Emergency stop pattern for security |
| **Gas Price Oracle** | Track and predict optimal gas prices |
| **Upgradeable Contracts** | UUPS proxy pattern for future upgrades |
| **Permit Tokens** | ERC20 with gasless approval support |

---

## Quick Start

```bash
# Clone and install
git clone https://github.com/Ask-812/Web3.git
cd web3
npm install

# Compile contracts
npx hardhat compile

# Run tests
npx hardhat test

# Deploy locally
npx hardhat node
npx hardhat run scripts/deploy.js --network localhost

# Run demo
npx hardhat run scripts/demo.js --network localhost
```

---

## Installation

### Prerequisites

- Node.js v18+ 
- npm or yarn
- Git

### Step 1: Install Dependencies

```bash
npm install
```

> **Note:** If you encounter peer dependency conflicts, run `npm install --legacy-peer-deps`

### Step 2: Compile Smart Contracts

```bash
npx hardhat compile
```

### Step 3: Configure Environment (Optional)

Create a `.env` file for testnet/mainnet deployment:

```env
PRIVATE_KEY=your_private_key_here
INFURA_API_KEY=your_infura_key_here
ETHERSCAN_API_KEY=your_etherscan_key_here
```

---

## Usage

### 1. Direct Batch Execution

Users can batch their own transactions (they still pay gas, but for all actions at once):

```javascript
const { ethers } = require("hardhat");

// Prepare multiple calls
const calls = [
  {
    target: sampleDApp.address,
    value: 0,
    data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Alice", "Developer"])
  },
  {
    target: sampleDApp.address,
    value: 0,
    data: sampleDApp.interface.encodeFunctionData("createListing", ["NFT #1", ethers.parseEther("0.1")])
  },
  {
    target: sampleDApp.address,
    value: 0,
    data: sampleDApp.interface.encodeFunctionData("createListing", ["NFT #2", ethers.parseEther("0.2")])
  }
];

// Execute all in one transaction
const tx = await batchExecutor.executeBatch(calls);
await tx.wait();

console.log("3 actions executed in 1 transaction!");
```

### 2. Meta-Transaction (Gasless)

Users sign off-chain; relayers submit on-chain:

```javascript
// User side: Sign the request (NO GAS REQUIRED)
const nonce = await batchExecutor.getNonce(user.address);
const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour

const batchRequest = {
  from: user.address,
  calls: calls,
  nonce: nonce,
  deadline: deadline
};

// Create EIP-712 signature
const signature = await user.signTypedData(domain, types, value);

// Relayer side: Submit the transaction
await batchExecutor.connect(relayer).executeBatchMeta(batchRequest, signature);
// Relayer pays gas, user pays nothing!
```

### 3. Gas Sponsorship

Configure sponsorship for your users:

```javascript
// Deploy with funding
await gasSponsor.deposit({ value: ethers.parseEther("10") });

// Configure sponsorship
await gasSponsor.updateConfig({
  isActive: true,
  maxGasPerTx: 500000,       // Max gas per transaction
  maxGasPerDay: 2000000,     // Daily limit per user
  sponsorshipPercent: 100,   // 100% sponsored
  minBalance: ethers.parseEther("0.01")
});

// Whitelist specific users (optional)
await gasSponsor.setWhitelistedUsers([user1.address, user2.address], true);

// Register relayers
await gasSponsor.setRelayer(relayer.address, true);
```

---

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed architecture documentation.

### High-Level Flow

```
┌──────────┐     ┌──────────┐     ┌───────────────┐     ┌──────────────┐
│   User   │────>│  Signs   │────>│   Relayer     │────>│ BatchExecutor│
│          │     │ Off-chain│     │  Submits Tx   │     │   Contract   │
└──────────┘     └──────────┘     └───────────────┘     └──────────────┘
                                         │                      │
                                         │                      ▼
                                         │              ┌──────────────┐
                                         └─────────────>│ Target       │
                                                        │ Contracts    │
                                                        └──────────────┘
```

---

## Smart Contracts

### Contract Files

| Contract | Description |
|----------|-------------|
| `BatchExecutor.sol` | Core batching and meta-transaction executor |
| `CompressedBatchExecutor.sol` | Calldata-compressed batch executor with context preservation |
| `GasSponsor.sol` | Gas sponsorship management |
| `Forwarder.sol` | EIP-2771 compliant forwarder |
| `MetaTxRecipient.sol` | Base contract for meta-tx recipients |
| `GaslessToken.sol` | Example ERC20 with meta-tx support |
| `SampleDApp.sol` | Demo application for testing |
| `SampleDAppMeta.sol` | EIP-2771 compatible demo dApp with meta-tx support |
| `Multicall3.sol` | Industry-standard batching (aggregate, tryAggregate) |
| `PermitToken.sol` | ERC20 with EIP-2612 gasless approvals |
| `CircuitBreaker.sol` | Emergency stop pattern with rate limiting |
| `GasPriceOracle.sol` | Gas price tracking and predictions |
| `BatchExecutorUpgradeable.sol` | UUPS proxy upgradeable version |
| `SimpleAccount.sol` | EIP-4337 smart contract wallet |
| `EntryPoint.sol` | EIP-4337 entry point |
| `Paymasters.sol` | Gas fee paymaster contracts |

### Key Functions

#### BatchExecutor

```solidity
// Execute batch directly (user pays gas)
function executeBatch(Call[] calldata calls) external payable returns (bytes[] memory)

// Execute via meta-transaction (relayer pays gas)
function executeBatchMeta(BatchRequest calldata request, bytes calldata signature) external returns (bytes[] memory)

// Get user's current nonce
function getNonce(address account) external view returns (uint256)

// Get gas statistics
function getGasStats() external view returns (uint256 totalSaved, uint256 batchCount)
```

#### GasSponsor

```solidity
// Check if user is eligible for sponsorship
function checkEligibility(address user, uint256 gasAmount) external view returns (bool eligible, uint256 sponsorableAmount)

// Get user's quota status
function getUserQuotaStatus(address user) external view returns (uint256 totalSponsored, uint256 dailyRemaining, bool isWhitelisted)

// Admin: Update configuration
function updateConfig(SponsorshipConfig calldata config) external

// Admin: Register relayers
function setRelayer(address relayer, bool active) external
```

---

## Testing

### Run All Tests

```bash
npx hardhat test
```

### Run Specific Test File

```bash
npx hardhat test test/GasOptimizer.test.js
npx hardhat test test/Advanced.test.js
```

### Run with Gas Reporting

```bash
REPORT_GAS=true npx hardhat test
```

### Test Coverage

```bash
npx hardhat coverage
```

### Expected Output (66 Tests)

```
  Advanced Gas Optimizer Features
    Multicall3
      ✓ should aggregate multiple calls successfully
      ✓ should handle tryAggregate with failures
      ✓ should return correct block data
      ...
    GaslessPermitToken
      ✓ should support EIP-2612 permit
      ...
    CircuitBreaker
      ✓ should start in closed state
      ✓ should open circuit on guardian call
      ...
    Performance Benchmarks
      Gas Savings at Different Batch Sizes:
         Batch Size 5:  12% savings
         Batch Size 10: 15% savings
         Batch Size 20: 17% savings
      ✓ should demonstrate scaling gas savings

  Gas Fee Optimizer
    BatchExecutor
      Direct Batch Execution
        ✓ should execute a single call batch
        ✓ should execute multiple calls in a batch
        ...
      Meta-Transaction Batch Execution
        ✓ should execute a batch via meta-transaction
        ✓ should reject expired meta-transactions
        ...
    GasSponsor
      ✓ should have correct default configuration
      ...
    Gas Savings Comparison
        ✓ should demonstrate gas savings from batching

    Gas Comparison Results:
    Individual transactions total: 656,652 gas
    Batched transaction total:     619,126 gas
    Gas saved:                     37,526 gas (5%)

  66 passing
```

---

## Gas Savings Demo

Run the demo script to see gas savings in action:

```bash
npx hardhat run scripts/demo.js --network localhost
```

### Sample Output

```
============================================
Gas Fee Optimizer - Demo Script
============================================

DEMO 1: Individual Transactions (Baseline)
============================================
Tx 1: Updating profile...     Gas used: 45,234
Tx 2: Creating listing 1...   Gas used: 89,456
Tx 3: Creating listing 2...   Gas used: 72,345
Tx 4: Creating listing 3...   Gas used: 72,345

Total gas for 4 individual transactions: 279,380

DEMO 2: Batched Transactions
============================================
Executing batch with 4 calls...
   Gas used: 196,567

Gas Comparison:
   Individual transactions: 279,380 gas
   Batched transaction:     196,567 gas
   Gas saved:               82,813 gas (12%)

DEMO 2B: Compressed Batch (Calldata Optimized)
============================================
Executing compressed batch with 4 calls (single target)...
   Gas used: 196,012

Gas Comparison (all 3 modes):
   Individual:  279,380 gas (baseline)
   Std Batch:   196,567 gas (12% saved)
   Compressed:  196,012 gas (13% saved)

DEMO 3: Meta-Transaction (Gasless)
============================================
User signing meta-transaction off-chain...
(No gas required for signing!)
Signature created: 0x8a7b...

Relayer submitting transaction on-chain...
Meta-transaction executed! Gas used: 185,432

Balance Changes:
   User balance change:    0 ETH
   Relayer balance change: -0.00185 ETH

User paid ZERO gas! Relayer covered the cost.
```

---

## Security

### Security Features

1. **Replay Protection**
   - Unique nonce per user
   - Atomically incremented on each transaction
   - Prevents replay attacks

2. **Signature Verification**
   - EIP-712 typed data signing
   - Domain separator includes chainId and contract address
   - Prevents cross-chain and cross-contract signature reuse

3. **Deadline Enforcement**
   - Transactions expire after specified deadline
   - Prevents indefinite signature validity

4. **Reentrancy Protection**
   - OpenZeppelin's ReentrancyGuard
   - Protects against reentrancy attacks

5. **Access Control**
   - Ownable for admin functions
   - Optional relayer whitelist

### Security Considerations

**Important Security Notes:**

1. **Relayer Trust**: While relayers cannot forge signatures, they can choose not to relay transactions (liveness concern). Use multiple relayers for redundancy.

2. **Signature Storage**: Never store user signatures. They should be used immediately or stored securely off-chain with user consent.

3. **Gas Estimation**: Always estimate gas before submitting. Failed transactions still consume gas.

4. **Contract Verification**: Always verify deployed contract addresses before interacting.

### Audit Status

- [ ] Internal review completed
- [ ] External audit pending

---

## Limitations

### Current Limitations

1. **Single Chain**: No cross-chain support. Each chain requires separate deployment.

2. **Relayer Centralization**: Requires trusted relayers. Consider decentralized relayer networks for production.

3. **Gas Price Fluctuations**: Gas sponsorship doesn't account for price spikes. Add buffer to quotas.

4. **Batch Size Limits**: Very large batches may exceed block gas limits.

### Known Issues

- Meta-transaction signature verification adds ~30k gas overhead
- Large calldata increases gas costs significantly
- Very small batches (2 calls) may not save gas due to overhead

### Implemented Features (Previously Planned)

- [x] Upgradeable contracts (UUPS proxy pattern)
- [x] EIP-4337 Account Abstraction support (simplified)
- [x] Gas price oracle integration
- [x] EIP-2612 Permit support
- [x] Circuit breaker emergency stop pattern

### Future Improvements

- [ ] Cross-chain support
- [ ] Decentralized relayer network integration
- [ ] Full EIP-4337 bundler integration

---

## Project Structure

```
web3/
├── contracts/
│   ├── BatchExecutor.sol           # Core batch executor with meta-tx
│   ├── CompressedBatchExecutor.sol  # Calldata-compressed batch executor
│   ├── GasSponsor.sol              # Gas sponsorship management
│   ├── Forwarder.sol               # EIP-2771 forwarder
│   ├── MetaTxRecipient.sol         # Base for meta-tx recipients
│   ├── GaslessToken.sol            # Example gasless ERC20
│   ├── SampleDApp.sol              # Demo application
│   ├── SampleDAppMeta.sol          # EIP-2771 compatible demo dApp
│   ├── AccountAbstraction/         # EIP-4337 contracts
│   │   ├── EntryPoint.sol          # Account abstraction entry point
│   │   ├── SimpleAccount.sol       # Smart contract wallet
│   │   └── Paymasters.sol          # Gas fee sponsors
│   ├── batching/
│   │   └── Multicall3.sol          # Industry-standard multicall
│   ├── permit/
│   │   └── PermitToken.sol         # ERC20 with EIP-2612 permit
│   ├── security/
│   │   └── CircuitBreaker.sol      # Emergency stop pattern
│   ├── test/
│   │   └── Counter.sol             # Simple test helper contract
│   ├── upgradeable/
│   │   └── BatchExecutorUpgradeable.sol  # UUPS upgradeable version
│   └── utils/
│       └── GasPriceOracle.sol      # Gas price tracking & predictions
├── scripts/
│   ├── deploy.js                   # Deployment script
│   ├── demo.js                     # Demo script showing savings
│   └── e2e-relayer-demo.js         # End-to-end relayer demo
├── test/
│   ├── GasOptimizer.test.js        # Core functionality tests
│   ├── Advanced.test.js            # Advanced features tests
│   └── Compressed.test.js          # Compressed batch comparison tests
├── frontend/
│   ├── index.html                  # Web interface
│   └── serve.js                    # Local development server
├── sdk/
│   └── GasOptimizerSDK.ts          # TypeScript SDK
├── relayer/
│   ├── server.js                   # Node.js relayer service
│   └── package.json                # Relayer dependencies
├── docs/
│   ├── ARCHITECTURE.md             # System architecture
│   ├── COMPLETE_GUIDE.md           # Comprehensive learning guide
│   ├── PRESENTATION_GUIDE.md       # Demo walkthrough & presentation tips
│   └── TECHNICAL_DEEP_DIVE.md      # In-depth technical documentation
├── hardhat.config.js               # Hardhat configuration
├── package.json
└── README.md
```

---

## Frontend

A web interface is provided in `frontend/`:

1. Start local Hardhat node:
   ```bash
   npx hardhat node
   ```

2. Deploy contracts:
   ```bash
   npx hardhat run scripts/deploy.js --network localhost
   ```

3. Start the frontend server:
   ```bash
   node frontend/serve.js
   ```

4. Open `http://localhost:8080` in your browser

5. Connect MetaMask to localhost:8545

6. Contract addresses auto-load from deployment — start batching!

---

## TypeScript SDK

A TypeScript SDK is provided for easy integration in `sdk/GasOptimizerSDK.ts`:

```typescript
import { GasOptimizerSDK, BatchBuilder } from './sdk/GasOptimizerSDK';

// Initialize SDK
const sdk = new GasOptimizerSDK(provider, signer, batchExecutorAddress);

// Build a batch using fluent API
const batch = new BatchBuilder(sampleDAppAddress, sampleDAppAbi)
  .addCall('updateProfile', ['Alice', 'Developer'])
  .addCall('createListing', ['NFT #1', ethers.parseEther('0.1')])
  .addCall('createListing', ['NFT #2', ethers.parseEther('0.2')]);

// Execute directly
await sdk.executeBatch(batch.getCalls());

// Or as a meta-transaction (gasless)
const signature = await sdk.signBatchRequest(batch.getCalls(), deadline);
await sdk.relayBatch(batch.getCalls(), deadline, signature);
```

---

## Relayer Service

A Node.js relayer service is provided in `relayer/`:

```bash
# Install relayer dependencies
cd relayer
npm install

# Start the relayer
npm start
```

**API Endpoints:**

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/status` | GET | Relayer status and stats |
| `/nonce/:address` | GET | Get user's nonce |
| `/relay/batch` | POST | Submit batch meta-transaction |
| `/relay/forward` | POST | Submit forward request |
| `/gas-price` | GET | Current gas prices |

**Example request:**

```bash
curl -X POST http://localhost:3000/relay/batch \
  -H "Content-Type: application/json" \
  -d '{
    "from": "0x...",
    "calls": [...],
    "nonce": 0,
    "deadline": 1740524400,
    "signature": "0x..."
  }'
```

---

## Live Deployment (Sepolia Testnet)

The system is deployed and fully functional on the Ethereum Sepolia testnet.

### Deployed UI

**https://ask-812.github.io/Web3/**

### Relayer Service

**https://relayer-sigma.vercel.app** (Vercel serverless)

### Contract Addresses (Sepolia)

| Contract | Address |
|----------|---------|
| BatchExecutor | `0x2c61E8959b5602C1DD9399fB16ABE9182fc7E3E7` |
| CompressedBatchExecutor | `0x01eAA34feF31F33E5EB15C5084569C1399B9C0CB` |
| SampleDApp | `0x47FF1aCB49cf23C28AA5887FC3bb5073D566f938` |
| SampleDAppMeta | `0xAE3329Cec2A4827dd13E9b86874CF175179B0E54` |
| GasSponsor | `0x856371cEED89a9c14E038e9cd3BF7026B004C663` |
| Forwarder | `0x21a94492478f4A00d29774c3754Ca8aB24FB8c9f` |
| GaslessToken | `0x66Eb4Fe980a960FC04553591c156e5DeDb9d7809` |

### Live Test Results (Sepolia, 5-Call Benchmark)

| Execution Mode | Gas Used | Savings vs Individual |
|---|---|---|
| Individual (5 separate txs) | 822,578 gas | — (baseline) |
| Standard Batch (1 tx) | 776,980 gas | 5.5% |
| Compressed Batch (1 tx) | 765,597 gas | 6.9% |
| Meta-Tx via Relayer (gasless) | 695,423 gas | **15.5% — user paid ZERO gas** |

All four execution modes verified end-to-end with real on-chain Sepolia transactions.

---

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `npx hardhat test`
5. Submit a pull request

---

## Acknowledgments

- [OpenZeppelin](https://openzeppelin.com/) - Security libraries
- [Hardhat](https://hardhat.org/) - Development framework
- [Web3Assam](https://web3assam.com/) - KRITI 2026 hackathon
- Ethereum community for EIP standards

---

## Contact

For questions or support, please open an issue on GitHub.

---

**Built for Web3Assam KRITI 2026**
