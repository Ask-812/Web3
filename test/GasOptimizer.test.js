const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("Gas Fee Optimizer", function () {
  let batchExecutor;
  let gasSponsor;
  let forwarder;
  let sampleDApp;
  let gaslessToken;
  let owner;
  let user1;
  let user2;
  let relayer;

  beforeEach(async function () {
    [owner, user1, user2, relayer] = await ethers.getSigners();

    // Deploy BatchExecutor
    const BatchExecutor = await ethers.getContractFactory("BatchExecutor");
    batchExecutor = await BatchExecutor.deploy();

    // Deploy GasSponsor
    const GasSponsor = await ethers.getContractFactory("GasSponsor");
    gasSponsor = await GasSponsor.deploy(await batchExecutor.getAddress());

    // Deploy Forwarder
    const Forwarder = await ethers.getContractFactory("Forwarder");
    forwarder = await Forwarder.deploy();

    // Deploy SampleDApp
    const SampleDApp = await ethers.getContractFactory("SampleDApp");
    sampleDApp = await SampleDApp.deploy();

    // Deploy GaslessToken
    const GaslessToken = await ethers.getContractFactory("GaslessToken");
    gaslessToken = await GaslessToken.deploy(await forwarder.getAddress());

    // Configure
    await batchExecutor.setGasSponsor(await gasSponsor.getAddress());
    await gasSponsor.setRelayer(relayer.address, true);
    await gasSponsor.deposit({ value: ethers.parseEther("1") });
  });

  describe("BatchExecutor", function () {
    describe("Direct Batch Execution", function () {
      it("should execute a single call batch", async function () {
        const calls = [{
          target: await sampleDApp.getAddress(),
          value: 0n,
          data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Alice", "Developer"])
        }];

        await batchExecutor.connect(user1).executeBatch(calls);

        // Note: When called through BatchExecutor, msg.sender in SampleDApp is the BatchExecutor
        // The profile is stored under BatchExecutor's address
        const batchExecutorAddr = await batchExecutor.getAddress();
        const profile = await sampleDApp.getProfile(batchExecutorAddr);
        expect(profile.username).to.equal("Alice");
        expect(profile.bio).to.equal("Developer");
      });

      it("should execute multiple calls in a batch", async function () {
        const calls = [
          {
            target: await sampleDApp.getAddress(),
            value: 0n,
            data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Bob", "Blockchain Expert"])
          },
          {
            target: await sampleDApp.getAddress(),
            value: 0n,
            data: sampleDApp.interface.encodeFunctionData("createListing", ["NFT #1", ethers.parseEther("0.1")])
          },
          {
            target: await sampleDApp.getAddress(),
            value: 0n,
            data: sampleDApp.interface.encodeFunctionData("createListing", ["NFT #2", ethers.parseEther("0.2")])
          }
        ];

        await batchExecutor.connect(user1).executeBatch(calls);

        // Profile stored under BatchExecutor's address
        const batchExecutorAddr = await batchExecutor.getAddress();
        const profile = await sampleDApp.getProfile(batchExecutorAddr);
        expect(profile.username).to.equal("Bob");
        expect(profile.totalTransactions).to.equal(2n); // 2 listings created

        const stats = await sampleDApp.getStats();
        expect(stats._totalListings).to.equal(2n);
      });

      it("should revert on empty batch", async function () {
        await expect(batchExecutor.connect(user1).executeBatch([]))
          .to.be.revertedWithCustomError(batchExecutor, "EmptyBatch");
      });

      it("should revert if any call fails", async function () {
        const calls = [
          {
            target: await sampleDApp.getAddress(),
            value: 0n,
            data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Test", "Bio"])
          },
          {
            target: await sampleDApp.getAddress(),
            value: 0n,
            // This will fail - trying to update listing that doesn't exist
            data: sampleDApp.interface.encodeFunctionData("updateListing", [999n, ethers.parseEther("1")])
          }
        ];

        await expect(batchExecutor.connect(user1).executeBatch(calls))
          .to.be.revertedWithCustomError(batchExecutor, "CallFailed");
      });

      it("should track gas statistics", async function () {
        const calls = [{
          target: await sampleDApp.getAddress(),
          value: 0n,
          data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Test", "Bio"])
        }];

        await batchExecutor.connect(user1).executeBatch(calls);

        const stats = await batchExecutor.getGasStats();
        expect(stats.batchCount).to.equal(1n);
      });
    });

    describe("Meta-Transaction Batch Execution", function () {
      it("should execute a batch via meta-transaction", async function () {
        const nonce = await batchExecutor.getNonce(user1.address);
        const deadline = (await time.latest()) + 3600;

        const calls = [
          {
            target: await sampleDApp.getAddress(),
            value: 0n,
            data: sampleDApp.interface.encodeFunctionData("updateProfile", ["MetaUser", "Gasless"])
          },
          {
            target: await sampleDApp.getAddress(),
            value: 0n,
            data: sampleDApp.interface.encodeFunctionData("createListing", ["Meta NFT", ethers.parseEther("0.5")])
          }
        ];

        const batchRequest = {
          from: user1.address,
          calls: calls,
          nonce: nonce,
          deadline: deadline
        };

        // Create EIP-712 signature
        const domain = {
          name: "GasOptimizer",
          version: "1",
          chainId: (await ethers.provider.getNetwork()).chainId,
          verifyingContract: await batchExecutor.getAddress()
        };

        const types = {
          BatchExecution: [
            { name: "from", type: "address" },
            { name: "callsHash", type: "bytes32" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint256" }
          ]
        };

        // Hash calls
        function hashCalls(calls) {
          const callHashes = calls.map(call => 
            ethers.keccak256(
              ethers.AbiCoder.defaultAbiCoder().encode(
                ["address", "uint256", "bytes32"],
                [call.target, call.value, ethers.keccak256(call.data)]
              )
            )
          );
          return ethers.keccak256(ethers.concat(callHashes));
        }

        const callsHash = hashCalls(calls);
        const value = {
          from: user1.address,
          callsHash: callsHash,
          nonce: nonce,
          deadline: deadline
        };

        const signature = await user1.signTypedData(domain, types, value);

        // User1's balance should not change (relayer pays)
        const user1BalanceBefore = await ethers.provider.getBalance(user1.address);
        
        // Relayer executes the meta-transaction
        await batchExecutor.connect(relayer).executeBatchMeta(batchRequest, signature);

        const user1BalanceAfter = await ethers.provider.getBalance(user1.address);
        expect(user1BalanceAfter).to.equal(user1BalanceBefore); // User paid no gas

        // Verify the calls were executed (profile stored under BatchExecutor's address)
        const batchExecutorAddr = await batchExecutor.getAddress();
        const profile = await sampleDApp.getProfile(batchExecutorAddr);
        expect(profile.username).to.equal("MetaUser");
      });

      it("should reject expired meta-transactions", async function () {
        const nonce = await batchExecutor.getNonce(user1.address);
        const deadline = (await time.latest()) - 3600; // Expired

        const batchRequest = {
          from: user1.address,
          calls: [{
            target: await sampleDApp.getAddress(),
            value: 0n,
            data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Test", "Bio"])
          }],
          nonce: nonce,
          deadline: deadline
        };

        await expect(batchExecutor.connect(relayer).executeBatchMeta(batchRequest, "0x00"))
          .to.be.revertedWithCustomError(batchExecutor, "ExpiredDeadline");
      });

      it("should reject invalid nonce", async function () {
        const deadline = (await time.latest()) + 3600;

        const batchRequest = {
          from: user1.address,
          calls: [{
            target: await sampleDApp.getAddress(),
            value: 0n,
            data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Test", "Bio"])
          }],
          nonce: 999n, // Wrong nonce
          deadline: deadline
        };

        await expect(batchExecutor.connect(relayer).executeBatchMeta(batchRequest, "0x00"))
          .to.be.revertedWithCustomError(batchExecutor, "InvalidNonce");
      });
    });

    describe("Relayer Authorization", function () {
      it("should allow owner to authorize relayers", async function () {
        await batchExecutor.setRelayerAuthorization(user2.address, true);
        expect(await batchExecutor.isRelayerAuthorized(user2.address)).to.be.true;
      });

      it("should allow owner to revoke relayers", async function () {
        await batchExecutor.setRelayerAuthorization(user2.address, true);
        await batchExecutor.setRelayerAuthorization(user2.address, false);
        expect(await batchExecutor.isRelayerAuthorized(user2.address)).to.be.false;
      });

      it("should enforce relayer whitelist when enabled", async function () {
        await batchExecutor.setRelayerWhitelistEnabled(true);

        const nonce = await batchExecutor.getNonce(user1.address);
        const deadline = (await time.latest()) + 3600;

        const batchRequest = {
          from: user1.address,
          calls: [{
            target: await sampleDApp.getAddress(),
            value: 0n,
            data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Test", "Bio"])
          }],
          nonce: nonce,
          deadline: deadline
        };

        // User2 is not authorized as relayer
        await expect(batchExecutor.connect(user2).executeBatchMeta(batchRequest, "0x00"))
          .to.be.revertedWithCustomError(batchExecutor, "UnauthorizedRelayer");
      });
    });
  });

  describe("GasSponsor", function () {
    describe("Configuration", function () {
      it("should have correct default configuration", async function () {
        const config = await gasSponsor.config();
        expect(config.isActive).to.be.true;
        expect(config.maxGasPerTx).to.equal(500000n);
        expect(config.sponsorshipPercent).to.equal(100n);
      });

      it("should allow owner to update config", async function () {
        const newConfig = {
          isActive: true,
          maxGasPerTx: 1000000n,
          maxGasPerDay: 5000000n,
          sponsorshipPercent: 50n,
          minBalance: ethers.parseEther("0.1")
        };

        await gasSponsor.updateConfig(newConfig);

        const config = await gasSponsor.config();
        expect(config.maxGasPerTx).to.equal(1000000n);
        expect(config.sponsorshipPercent).to.equal(50n);
      });

      it("should reject invalid sponsorship percent", async function () {
        const newConfig = {
          isActive: true,
          maxGasPerTx: 500000n,
          maxGasPerDay: 2000000n,
          sponsorshipPercent: 101n, // Invalid - over 100%
          minBalance: 0n
        };

        await expect(gasSponsor.updateConfig(newConfig))
          .to.be.revertedWithCustomError(gasSponsor, "InvalidConfiguration");
      });
    });

    describe("Relayer Management", function () {
      it("should register relayers", async function () {
        const relayerInfo = await gasSponsor.relayers(relayer.address);
        expect(relayerInfo.isActive).to.be.true;
      });

      it("should allow adding multiple relayers", async function () {
        await gasSponsor.setRelayer(user1.address, true);
        await gasSponsor.setRelayer(user2.address, true);

        expect((await gasSponsor.relayers(user1.address)).isActive).to.be.true;
        expect((await gasSponsor.relayers(user2.address)).isActive).to.be.true;
      });
    });

    describe("User Whitelist", function () {
      it("should whitelist users", async function () {
        await gasSponsor.setWhitelistedUsers([user1.address, user2.address], true);

        const quota1 = await gasSponsor.userQuotas(user1.address);
        const quota2 = await gasSponsor.userQuotas(user2.address);

        expect(quota1.isWhitelisted).to.be.true;
        expect(quota2.isWhitelisted).to.be.true;
      });

      it("should check eligibility correctly", async function () {
        const [eligible, amount] = await gasSponsor.checkEligibility(user1.address, 100000n);
        expect(eligible).to.be.true;
        expect(amount).to.equal(100000n); // 100% sponsorship
      });
    });

    describe("Funding", function () {
      it("should accept deposits", async function () {
        const balanceBefore = await ethers.provider.getBalance(await gasSponsor.getAddress());
        
        await gasSponsor.connect(user1).deposit({ value: ethers.parseEther("0.5") });

        const balanceAfter = await ethers.provider.getBalance(await gasSponsor.getAddress());
        expect(balanceAfter - balanceBefore).to.equal(ethers.parseEther("0.5"));
      });

      it("should allow owner to withdraw", async function () {
        const ownerBalanceBefore = await ethers.provider.getBalance(owner.address);
        
        await gasSponsor.withdraw(user2.address, ethers.parseEther("0.5"));

        const user2Balance = await ethers.provider.getBalance(user2.address);
        expect(user2Balance).to.be.gt(ethers.parseEther("10000")); // Started with 10000, now has more
      });

      it("should emit stats correctly", async function () {
        const stats = await gasSponsor.getStats();
        expect(stats.balance).to.equal(ethers.parseEther("1")); // Initial deposit
        expect(stats.isActive).to.be.true;
      });
    });
  });

  describe("Forwarder (EIP-2771)", function () {
    describe("Forward Execution", function () {
      it("should execute a forward request", async function () {
        const nonce = await forwarder.getNonce(user1.address);
        const deadline = (await time.latest()) + 3600;

        const request = {
          from: user1.address,
          to: await sampleDApp.getAddress(),
          value: 0n,
          gas: 200000n,
          nonce: nonce,
          deadline: deadline,
          data: sampleDApp.interface.encodeFunctionData("updateProfile", ["ForwardedUser", "Via Forwarder"])
        };

        // Get the request hash for signing
        const types = {
          ForwardRequest: [
            { name: "from", type: "address" },
            { name: "to", type: "address" },
            { name: "value", type: "uint256" },
            { name: "gas", type: "uint256" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint48" },
            { name: "data", type: "bytes" }
          ]
        };

        const domain = {
          name: "GasOptimizer Forwarder",
          version: "1",
          chainId: (await ethers.provider.getNetwork()).chainId,
          verifyingContract: await forwarder.getAddress()
        };

        const signature = await user1.signTypedData(domain, types, request);

        // Verify signature
        expect(await forwarder.verify(request, signature)).to.be.true;

        // Execute
        await forwarder.connect(relayer).execute(request, signature);

        // Note: SampleDApp doesn't use _msgSender(), so it will see msg.sender as forwarder
        // In a real implementation, SampleDApp would inherit from MetaTxRecipient
      });

      it("should increment nonce after execution", async function () {
        const nonceBefore = await forwarder.getNonce(user1.address);
        const deadline = (await time.latest()) + 3600;

        const request = {
          from: user1.address,
          to: await sampleDApp.getAddress(),
          value: 0n,
          gas: 200000n,
          nonce: nonceBefore,
          deadline: deadline,
          data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Test", "Test"])
        };

        const types = {
          ForwardRequest: [
            { name: "from", type: "address" },
            { name: "to", type: "address" },
            { name: "value", type: "uint256" },
            { name: "gas", type: "uint256" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint48" },
            { name: "data", type: "bytes" }
          ]
        };

        const domain = {
          name: "GasOptimizer Forwarder",
          version: "1",
          chainId: (await ethers.provider.getNetwork()).chainId,
          verifyingContract: await forwarder.getAddress()
        };

        const signature = await user1.signTypedData(domain, types, request);
        await forwarder.connect(relayer).execute(request, signature);

        const nonceAfter = await forwarder.getNonce(user1.address);
        expect(nonceAfter).to.equal(nonceBefore + 1n);
      });
    });
  });

  describe("GaslessToken", function () {
    it("should have correct initial supply", async function () {
      const totalSupply = await gaslessToken.totalSupply();
      expect(totalSupply).to.equal(ethers.parseEther("1000000"));
    });

    it("should allow batch transfers", async function () {
      // Transfer some tokens to user1 first
      await gaslessToken.transfer(user1.address, ethers.parseEther("1000"));

      // User1 batch transfers
      await gaslessToken.connect(user1).batchTransfer(
        [user2.address, relayer.address],
        [ethers.parseEther("100"), ethers.parseEther("200")]
      );

      expect(await gaslessToken.balanceOf(user2.address)).to.equal(ethers.parseEther("100"));
      expect(await gaslessToken.balanceOf(relayer.address)).to.equal(ethers.parseEther("200"));
    });
  });

  describe("Gas Savings Comparison", function () {
    it("should demonstrate gas savings from batching", async function () {
      // Individual transactions
      let totalGasIndividual = 0n;

      let tx = await sampleDApp.connect(user2).updateProfile("Test1", "Bio1");
      let receipt = await tx.wait();
      totalGasIndividual += receipt.gasUsed;

      tx = await sampleDApp.connect(user2).createListing("Item1", ethers.parseEther("0.1"));
      receipt = await tx.wait();
      totalGasIndividual += receipt.gasUsed;

      tx = await sampleDApp.connect(user2).createListing("Item2", ethers.parseEther("0.2"));
      receipt = await tx.wait();
      totalGasIndividual += receipt.gasUsed;

      tx = await sampleDApp.connect(user2).createListing("Item3", ethers.parseEther("0.3"));
      receipt = await tx.wait();
      totalGasIndividual += receipt.gasUsed;

      console.log(`\n    📊 Gas Comparison Results:`);
      console.log(`    Individual transactions total: ${totalGasIndividual} gas`);

      // Batched transaction
      const calls = [
        {
          target: await sampleDApp.getAddress(),
          value: 0n,
          data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Test2", "Bio2"])
        },
        {
          target: await sampleDApp.getAddress(),
          value: 0n,
          data: sampleDApp.interface.encodeFunctionData("createListing", ["BatchItem1", ethers.parseEther("0.1")])
        },
        {
          target: await sampleDApp.getAddress(),
          value: 0n,
          data: sampleDApp.interface.encodeFunctionData("createListing", ["BatchItem2", ethers.parseEther("0.2")])
        },
        {
          target: await sampleDApp.getAddress(),
          value: 0n,
          data: sampleDApp.interface.encodeFunctionData("createListing", ["BatchItem3", ethers.parseEther("0.3")])
        }
      ];

      tx = await batchExecutor.connect(user1).executeBatch(calls);
      receipt = await tx.wait();
      const totalGasBatched = receipt.gasUsed;

      console.log(`    Batched transaction total:     ${totalGasBatched} gas`);

      const gasSaved = totalGasIndividual - totalGasBatched;
      const savingsPercent = Number(gasSaved * 100n / totalGasIndividual);

      console.log(`    Gas saved:                     ${gasSaved} gas (${savingsPercent}%)\n`);

      // Verify batching saves gas
      expect(totalGasBatched).to.be.lt(totalGasIndividual);
    });
  });
});
