const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  console.log("============================================");
  console.log("Gas Fee Optimizer - Deployment Script");
  console.log("============================================\n");

  const [deployer, relayer] = await hre.ethers.getSigners();
  
  console.log("Deployer address:", deployer.address);
  console.log("Relayer address:", relayer?.address || "Not available");
  console.log("Deployer balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "ETH\n");

  // 1. Deploy BatchExecutor
  console.log("1. Deploying BatchExecutor...");
  const BatchExecutor = await hre.ethers.getContractFactory("BatchExecutor");
  const batchExecutor = await BatchExecutor.deploy();
  await batchExecutor.waitForDeployment();
  const batchExecutorAddress = await batchExecutor.getAddress();
  console.log("   BatchExecutor deployed to:", batchExecutorAddress);

  // 2. Deploy GasSponsor
  console.log("\n2. Deploying GasSponsor...");
  const GasSponsor = await hre.ethers.getContractFactory("GasSponsor");
  const gasSponsor = await GasSponsor.deploy(batchExecutorAddress);
  await gasSponsor.waitForDeployment();
  const gasSponsorAddress = await gasSponsor.getAddress();
  console.log("   GasSponsor deployed to:", gasSponsorAddress);

  // 3. Deploy Forwarder
  console.log("\n3. Deploying Forwarder...");
  const Forwarder = await hre.ethers.getContractFactory("Forwarder");
  const forwarder = await Forwarder.deploy();
  await forwarder.waitForDeployment();
  const forwarderAddress = await forwarder.getAddress();
  console.log("   Forwarder deployed to:", forwarderAddress);

  // 4. Deploy GaslessToken
  console.log("\n4. Deploying GaslessToken...");
  const GaslessToken = await hre.ethers.getContractFactory("GaslessToken");
  const gaslessToken = await GaslessToken.deploy(forwarderAddress);
  await gaslessToken.waitForDeployment();
  const gaslessTokenAddress = await gaslessToken.getAddress();
  console.log("   GaslessToken deployed to:", gaslessTokenAddress);

  // 5. Deploy SampleDApp
  console.log("\n5. Deploying SampleDApp...");
  const SampleDApp = await hre.ethers.getContractFactory("SampleDApp");
  const sampleDApp = await SampleDApp.deploy();
  await sampleDApp.waitForDeployment();
  const sampleDAppAddress = await sampleDApp.getAddress();
  console.log("   SampleDApp deployed to:", sampleDAppAddress);

  // 6. Configure contracts
  console.log("\n============================================");
  console.log("Configuring contracts...");
  console.log("============================================\n");

  // Link BatchExecutor to GasSponsor
  console.log("- Setting GasSponsor on BatchExecutor...");
  await batchExecutor.setGasSponsor(gasSponsorAddress);

  // Register deployer as a relayer (for testing)
  console.log("- Registering deployer as relayer on GasSponsor...");
  await gasSponsor.setRelayer(deployer.address, true);

  // If we have a second account, register it as relayer too
  if (relayer) {
    console.log("- Registering second account as relayer...");
    await gasSponsor.setRelayer(relayer.address, true);
    await batchExecutor.setRelayerAuthorization(relayer.address, true);
  }

  // Fund the GasSponsor with some ETH
  console.log("- Funding GasSponsor with 1 ETH...");
  await gasSponsor.deposit({ value: hre.ethers.parseEther("1") });

  console.log("\n============================================");
  console.log("Deployment Complete!");
  console.log("============================================\n");

  // Print summary
  const deploymentInfo = {
    network: hre.network.name,
    chainId: (await hre.ethers.provider.getNetwork()).chainId.toString(),
    contracts: {
      BatchExecutor: batchExecutorAddress,
      GasSponsor: gasSponsorAddress,
      Forwarder: forwarderAddress,
      GaslessToken: gaslessTokenAddress,
      SampleDApp: sampleDAppAddress
    },
    deployer: deployer.address
  };

  console.log("Deployment Info:");
  console.log(JSON.stringify(deploymentInfo, null, 2));

  // Save deployment info to file
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }
  
  const deploymentFile = path.join(deploymentsDir, `${hre.network.name}.json`);
  fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));
  console.log(`\nDeployment info saved to: ${deploymentFile}`);

  // Verify contracts on Etherscan if not on local network
  if (hre.network.name !== "hardhat" && hre.network.name !== "localhost") {
    console.log("\n============================================");
    console.log("Verifying contracts on Etherscan...");
    console.log("============================================\n");
    
    try {
      await hre.run("verify:verify", {
        address: batchExecutorAddress,
        constructorArguments: []
      });
      console.log("BatchExecutor verified!");
    } catch (e) {
      console.log("BatchExecutor verification failed:", e.message);
    }
  }

  return deploymentInfo;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
