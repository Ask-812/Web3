const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Demo Script - Gas Fee Optimizer Demonstration
 * 
 * This script demonstrates:
 * 1. Direct batch execution (user pays gas, but for all actions in one tx)
 * 2. Meta-transaction batch execution (relayer pays gas)
 * 3. Gas savings comparison
 */

async function main() {
  console.log("============================================");
  console.log("Gas Fee Optimizer - Demo Script");
  console.log("============================================\n");

  const [user, relayer] = await hre.ethers.getSigners();
  
  console.log("User address:", user.address);
  console.log("Relayer address:", relayer?.address || user.address);

  // Load deployment info
  const deploymentFile = path.join(__dirname, "..", "deployments", "hardhat.json");
  
  let contracts;
  if (fs.existsSync(deploymentFile)) {
    contracts = JSON.parse(fs.readFileSync(deploymentFile)).contracts;
  } else {
    console.log("Deployment file not found. Deploying inline...\n");
    // Deploy inline
    const BatchExecutor = await hre.ethers.getContractFactory("BatchExecutor");
    const batchExecutor = await BatchExecutor.deploy();
    const SampleDApp = await hre.ethers.getContractFactory("SampleDApp");
    const sampleDApp = await SampleDApp.deploy();
    contracts = {
      BatchExecutor: await batchExecutor.getAddress(),
      SampleDApp: await sampleDApp.getAddress()
    };
  }

  // Get contract instances
  const batchExecutor = await hre.ethers.getContractAt("BatchExecutor", contracts.BatchExecutor);
  const sampleDApp = await hre.ethers.getContractAt("SampleDApp", contracts.SampleDApp);
  
  console.log("\nContracts loaded:");
  console.log("- BatchExecutor:", contracts.BatchExecutor);
  console.log("- SampleDApp:", contracts.SampleDApp);

  // ============================================
  // DEMO 1: Individual Transactions (Baseline)
  // ============================================
  console.log("\n============================================");
  console.log("DEMO 1: Individual Transactions (Baseline)");
  console.log("============================================\n");

  let totalGasIndividual = 0n;

  // Transaction 1: Update profile
  console.log("Tx 1: Updating profile...");
  let tx = await sampleDApp.connect(user).updateProfile("Alice", "Web3 Developer from Assam");
  let receipt = await tx.wait();
  console.log(`   Gas used: ${receipt.gasUsed}`);
  totalGasIndividual += receipt.gasUsed;

  // Transaction 2: Create listing 1
  console.log("Tx 2: Creating listing 1...");
  tx = await sampleDApp.connect(user).createListing("NFT Art #1", hre.ethers.parseEther("0.1"));
  receipt = await tx.wait();
  console.log(`   Gas used: ${receipt.gasUsed}`);
  totalGasIndividual += receipt.gasUsed;

  // Transaction 3: Create listing 2
  console.log("Tx 3: Creating listing 2...");
  tx = await sampleDApp.connect(user).createListing("NFT Art #2", hre.ethers.parseEther("0.2"));
  receipt = await tx.wait();
  console.log(`   Gas used: ${receipt.gasUsed}`);
  totalGasIndividual += receipt.gasUsed;

  // Transaction 4: Create listing 3
  console.log("Tx 4: Creating listing 3...");
  tx = await sampleDApp.connect(user).createListing("NFT Art #3", hre.ethers.parseEther("0.3"));
  receipt = await tx.wait();
  console.log(`   Gas used: ${receipt.gasUsed}`);
  totalGasIndividual += receipt.gasUsed;

  console.log(`\n📊 Total gas for 4 individual transactions: ${totalGasIndividual}`);

  // ============================================
  // DEMO 2: Batched Transactions
  // ============================================
  console.log("\n============================================");
  console.log("DEMO 2: Batched Transactions");
  console.log("============================================\n");

  // Prepare the same 4 calls as a batch
  const calls = [
    {
      target: contracts.SampleDApp,
      value: 0n,
      data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Bob", "Blockchain Expert"])
    },
    {
      target: contracts.SampleDApp,
      value: 0n,
      data: sampleDApp.interface.encodeFunctionData("createListing", ["Batched NFT #1", hre.ethers.parseEther("0.15")])
    },
    {
      target: contracts.SampleDApp,
      value: 0n,
      data: sampleDApp.interface.encodeFunctionData("createListing", ["Batched NFT #2", hre.ethers.parseEther("0.25")])
    },
    {
      target: contracts.SampleDApp,
      value: 0n,
      data: sampleDApp.interface.encodeFunctionData("createListing", ["Batched NFT #3", hre.ethers.parseEther("0.35")])
    }
  ];

  console.log("Executing batch with 4 calls...");
  tx = await batchExecutor.connect(user).executeBatch(calls);
  receipt = await tx.wait();
  const totalGasBatched = receipt.gasUsed;
  console.log(`   Gas used: ${totalGasBatched}`);

  // Calculate savings
  const gasSaved = totalGasIndividual - totalGasBatched;
  const savingsPercent = Number((gasSaved * 100n) / totalGasIndividual);

  console.log("\n📊 Gas Comparison:");
  console.log(`   Individual transactions: ${totalGasIndividual} gas`);
  console.log(`   Batched transaction:     ${totalGasBatched} gas`);
  console.log(`   Gas saved:               ${gasSaved} gas (${savingsPercent}%)`);

  // ============================================
  // DEMO 3: Meta-Transaction (Gasless for User)
  // ============================================
  console.log("\n============================================");
  console.log("DEMO 3: Meta-Transaction (Gasless)");
  console.log("============================================\n");

  // Get user's nonce
  const nonce = await batchExecutor.getNonce(user.address);
  const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

  // Prepare batch request
  const batchRequest = {
    from: user.address,
    calls: [
      {
        target: contracts.SampleDApp,
        value: 0n,
        data: sampleDApp.interface.encodeFunctionData("createListing", ["Meta NFT #1", hre.ethers.parseEther("0.5")])
      },
      {
        target: contracts.SampleDApp,
        value: 0n,
        data: sampleDApp.interface.encodeFunctionData("createListing", ["Meta NFT #2", hre.ethers.parseEther("0.6")])
      }
    ],
    nonce: nonce,
    deadline: deadline
  };

  // Create EIP-712 signature
  const domain = {
    name: "GasOptimizer",
    version: "1",
    chainId: (await hre.ethers.provider.getNetwork()).chainId,
    verifyingContract: contracts.BatchExecutor
  };

  const types = {
    BatchExecution: [
      { name: "from", type: "address" },
      { name: "callsHash", type: "bytes32" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" }
    ]
  };

  // Hash the calls array
  function hashCalls(calls) {
    const callHashes = calls.map(call => 
      hre.ethers.keccak256(
        hre.ethers.AbiCoder.defaultAbiCoder().encode(
          ["address", "uint256", "bytes32"],
          [call.target, call.value, hre.ethers.keccak256(call.data)]
        )
      )
    );
    return hre.ethers.keccak256(hre.ethers.concat(callHashes));
  }

  const callsHash = hashCalls(batchRequest.calls);
  
  const value = {
    from: batchRequest.from,
    callsHash: callsHash,
    nonce: batchRequest.nonce,
    deadline: batchRequest.deadline
  };

  console.log("User signing meta-transaction off-chain...");
  console.log("(No gas required for signing!)");
  
  const signature = await user.signTypedData(domain, types, value);
  console.log("✅ Signature created:", signature.slice(0, 20) + "...");

  // Relayer submits the transaction
  console.log("\nRelayer submitting transaction on-chain...");
  const signerToUse = relayer || user;
  
  const userBalanceBefore = await hre.ethers.provider.getBalance(user.address);
  const relayerBalanceBefore = await hre.ethers.provider.getBalance(signerToUse.address);

  tx = await batchExecutor.connect(signerToUse).executeBatchMeta(batchRequest, signature);
  receipt = await tx.wait();

  const userBalanceAfter = await hre.ethers.provider.getBalance(user.address);
  const relayerBalanceAfter = await hre.ethers.provider.getBalance(signerToUse.address);

  console.log(`✅ Meta-transaction executed! Gas used: ${receipt.gasUsed}`);
  console.log(`\n📊 Balance Changes:`);
  console.log(`   User balance change:    ${hre.ethers.formatEther(userBalanceAfter - userBalanceBefore)} ETH`);
  console.log(`   Relayer balance change: ${hre.ethers.formatEther(relayerBalanceAfter - relayerBalanceBefore)} ETH`);
  console.log(`\n✅ User paid ZERO gas! Relayer covered the cost.`);

  // ============================================
  // Summary
  // ============================================
  console.log("\n============================================");
  console.log("SUMMARY - Gas Optimization Results");
  console.log("============================================\n");

  const stats = await batchExecutor.getGasStats();
  console.log(`Total batches executed: ${stats.batchCount}`);
  console.log(`Total estimated gas saved: ${stats.totalSaved}`);

  const profile = await sampleDApp.getProfile(user.address);
  console.log(`\nUser Profile: ${profile.username}`);
  console.log(`Total transactions by user: ${profile.totalTransactions}`);

  const dappStats = await sampleDApp.getStats();
  console.log(`\nSampleDApp Statistics:`);
  console.log(`- Total listings: ${dappStats._totalListings}`);
  console.log(`- Total bids: ${dappStats._totalBids}`);

  console.log("\n✅ Demo completed successfully!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
