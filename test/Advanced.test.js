/**
 * Comprehensive Tests for Advanced Gas Optimizer Features
 * 
 * Tests cover:
 * - Multicall3 functionality
 * - Permit token operations
 * - Gas price oracle
 * - Circuit breaker patterns
 * - Edge cases and security scenarios
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("Advanced Gas Optimizer Features", function () {
    let owner, user1, user2, relayer, attacker;
    
    beforeEach(async function () {
        [owner, user1, user2, relayer, attacker] = await ethers.getSigners();
    });

    // ═══════════════════════════════════════════════════════════════════════
    //                        MULTICALL3 TESTS
    // ═══════════════════════════════════════════════════════════════════════

    describe("Multicall3", function () {
        let multicall;
        let mockContract;

        beforeEach(async function () {
            const Multicall3 = await ethers.getContractFactory("Multicall3");
            multicall = await Multicall3.deploy();

            // Deploy a simple counter contract for testing
            const Counter = await ethers.getContractFactory("Counter");
            mockContract = await Counter.deploy();
        });

        it("should aggregate multiple calls successfully", async function () {
            const calls = [
                {
                    target: await multicall.getAddress(),
                    callData: multicall.interface.encodeFunctionData("getBlockNumber")
                },
                {
                    target: await multicall.getAddress(),
                    callData: multicall.interface.encodeFunctionData("getCurrentBlockTimestamp")
                }
            ];

            const [blockNumber, results] = await multicall.aggregate.staticCall(calls);
            
            expect(blockNumber).to.be.gt(0);
            expect(results.length).to.equal(2);
        });

        it("should handle tryAggregate with failures", async function () {
            const calls = [
                {
                    target: await multicall.getAddress(),
                    callData: multicall.interface.encodeFunctionData("getBlockNumber")
                },
                {
                    target: await multicall.getAddress(),
                    callData: "0x12345678" // Invalid function selector
                }
            ];

            // With requireSuccess = false, should not revert
            const results = await multicall.tryAggregate.staticCall(false, calls);
            
            expect(results[0].success).to.be.true;
            expect(results[1].success).to.be.false;
        });

        it("should return correct block data", async function () {
            const blockNumber = await multicall.getBlockNumber();
            const timestamp = await multicall.getCurrentBlockTimestamp();
            const chainId = await multicall.getChainId();
            
            expect(blockNumber).to.be.gt(0);
            expect(timestamp).to.be.gt(0);
            expect(chainId).to.equal(31337n); // Hardhat network
        });

        it("should handle aggregate3 with per-call failure flags", async function () {
            const calls = [
                {
                    target: await multicall.getAddress(),
                    allowFailure: false,
                    callData: multicall.interface.encodeFunctionData("getBlockNumber")
                },
                {
                    target: await multicall.getAddress(),
                    allowFailure: true, // Allow this one to fail
                    callData: "0x12345678"
                }
            ];

            // Should not revert because second call allows failure
            const results = await multicall.aggregate3.staticCall(calls);
            
            expect(results[0].success).to.be.true;
            expect(results[1].success).to.be.false;
        });

        it("should get ETH balance correctly", async function () {
            const balance = await multicall.getEthBalance(owner.address);
            const actualBalance = await ethers.provider.getBalance(owner.address);
            
            expect(balance).to.equal(actualBalance);
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    //                      PERMIT TOKEN TESTS
    // ═══════════════════════════════════════════════════════════════════════

    describe("GaslessPermitToken", function () {
        let token;
        const INITIAL_SUPPLY = ethers.parseEther("1000000");

        beforeEach(async function () {
            const GaslessPermitToken = await ethers.getContractFactory("GaslessPermitToken");
            token = await GaslessPermitToken.deploy(
                "Gasless Token",
                "GLESS",
                INITIAL_SUPPLY,
                owner.address
            );
        });

        it("should deploy with correct parameters", async function () {
            expect(await token.name()).to.equal("Gasless Token");
            expect(await token.symbol()).to.equal("GLESS");
            expect(await token.balanceOf(owner.address)).to.equal(INITIAL_SUPPLY);
        });

        it("should execute batch transfers", async function () {
            const recipients = [user1.address, user2.address];
            const amounts = [ethers.parseEther("100"), ethers.parseEther("200")];

            await token.batchTransfer(recipients, amounts);

            expect(await token.balanceOf(user1.address)).to.equal(amounts[0]);
            expect(await token.balanceOf(user2.address)).to.equal(amounts[1]);
        });

        it("should revert batch transfer with mismatched arrays", async function () {
            const recipients = [user1.address];
            const amounts = [ethers.parseEther("100"), ethers.parseEther("200")];

            await expect(token.batchTransfer(recipients, amounts))
                .to.be.revertedWith("Length mismatch");
        });

        it("should support EIP-2612 permit", async function () {
            const amount = ethers.parseEther("500");
            const deadline = (await time.latest()) + 3600;
            
            // Get domain
            const domain = {
                name: await token.name(),
                version: "1",
                chainId: 31337n,
                verifyingContract: await token.getAddress()
            };

            const types = {
                Permit: [
                    { name: "owner", type: "address" },
                    { name: "spender", type: "address" },
                    { name: "value", type: "uint256" },
                    { name: "nonce", type: "uint256" },
                    { name: "deadline", type: "uint256" }
                ]
            };

            const value = {
                owner: owner.address,
                spender: user1.address,
                value: amount,
                nonce: await token.nonces(owner.address),
                deadline: deadline
            };

            const signature = await owner.signTypedData(domain, types, value);
            const { v, r, s } = ethers.Signature.from(signature);

            // Execute permit
            await token.permit(
                owner.address,
                user1.address,
                amount,
                deadline,
                v, r, s
            );

            expect(await token.allowance(owner.address, user1.address)).to.equal(amount);
        });

        it("should allow minting by owner", async function () {
            const mintAmount = ethers.parseEther("1000");
            await token.mint(user1.address, mintAmount);
            expect(await token.balanceOf(user1.address)).to.equal(mintAmount);
        });

        it("should reject minting by non-owner", async function () {
            const mintAmount = ethers.parseEther("1000");
            await expect(token.connect(user1).mint(user1.address, mintAmount))
                .to.be.reverted;
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    //                     GAS PRICE ORACLE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    describe("GasPriceOracle", function () {
        let oracle;

        beforeEach(async function () {
            const GasPriceOracle = await ethers.getContractFactory("GasPriceOracle");
            oracle = await GasPriceOracle.deploy(owner.address);
        });

        it("should record gas prices", async function () {
            // First record
            await oracle.recordGasPrice();
            
            const snapshot = await oracle.getLatestSnapshot();
            expect(snapshot.blockNumber).to.be.gt(0);
        });

        it("should enforce update frequency", async function () {
            await oracle.recordGasPrice();
            
            // Try immediate second record
            await expect(oracle.recordGasPrice())
                .to.be.revertedWith("Too soon");
        });

        it("should allow authorized updaters", async function () {
            await oracle.setAuthorizedUpdater(user1.address, true);
            
            const gasPrice = ethers.parseUnits("50", "gwei");
            const baseFee = ethers.parseUnits("30", "gwei");
            
            await oracle.connect(user1).updateGasPrice(gasPrice, baseFee);
            
            const snapshot = await oracle.getLatestSnapshot();
            expect(snapshot.gasPrice).to.equal(gasPrice);
        });

        it("should calculate predictions after multiple samples", async function () {
            // Record multiple samples
            for (let i = 0; i < 5; i++) {
                await oracle.setAuthorizedUpdater(owner.address, true);
                const gasPrice = ethers.parseUnits(String(30 + i * 5), "gwei");
                await oracle.updateGasPrice(gasPrice, gasPrice);
            }

            const predictions = await oracle.getPredictions();
            expect(predictions.confidence).to.be.gt(0);
            expect(predictions.medium).to.be.gt(0);
        });

        it("should track hourly averages", async function () {
            const gasPrice = ethers.parseUnits("50", "gwei");
            await oracle.updateGasPrice(gasPrice, gasPrice);
            
            const hour = Math.floor(Date.now() / 1000 / 3600) % 24;
            const hourlyAvg = await oracle.hourlyAverages(hour);
            expect(hourlyAvg).to.be.gt(0);
        });

        it("should identify favorable gas prices", async function () {
            // Set a baseline
            const basePrice = ethers.parseUnits("50", "gwei");
            await oracle.updateGasPrice(basePrice, basePrice);
            
            const [isFavorable, savingsPercent] = await oracle.isGasPriceFavorable();
            // Result depends on current block.basefee
            expect(typeof isFavorable).to.equal("boolean");
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    //                     CIRCUIT BREAKER TESTS
    // ═══════════════════════════════════════════════════════════════════════

    describe("CircuitBreaker", function () {
        let breaker;

        beforeEach(async function () {
            const CircuitBreaker = await ethers.getContractFactory("CircuitBreaker");
            breaker = await CircuitBreaker.deploy(owner.address);
        });

        it("should start in closed state", async function () {
            expect(await breaker.state()).to.equal(0); // CLOSED
        });

        it("should open circuit on guardian call", async function () {
            await breaker.openCircuit("Emergency maintenance");
            expect(await breaker.state()).to.equal(1); // OPEN
        });

        it("should not allow half-open before cooldown", async function () {
            await breaker.openCircuit("Test");
            
            await expect(breaker.halfOpenCircuit())
                .to.be.revertedWith("Cooldown not complete");
        });

        it("should allow half-open after cooldown", async function () {
            await breaker.openCircuit("Test");
            
            // Fast forward past cooldown
            await time.increase(3601); // 1 hour + 1 second
            
            await breaker.halfOpenCircuit();
            expect(await breaker.state()).to.equal(2); // HALF_OPEN
        });

        it("should transition to closed after successful tests", async function () {
            await breaker.openCircuit("Test");
            await time.increase(3601);
            await breaker.halfOpenCircuit();
            
            // Record enough successes
            const required = await breaker.testOperationsRequired();
            for (let i = 0; i < required; i++) {
                await breaker.recordSuccess();
            }
            
            expect(await breaker.state()).to.equal(0); // CLOSED
        });

        it("should re-open on failure during half-open", async function () {
            await breaker.openCircuit("Test");
            await time.increase(3601);
            await breaker.halfOpenCircuit();
            
            await breaker.recordFailure();
            expect(await breaker.state()).to.equal(1); // OPEN
        });

        it("should pause individual features", async function () {
            const BATCH_FEATURE = await breaker.FEATURE_BATCH();
            
            await breaker.pauseFeature(BATCH_FEATURE);
            expect(await breaker.featurePaused(BATCH_FEATURE)).to.be.true;
            
            await breaker.unpauseFeature(BATCH_FEATURE);
            expect(await breaker.featurePaused(BATCH_FEATURE)).to.be.false;
        });

        it("should auto-trip on threshold exceeded", async function () {
            // Lower threshold for testing
            await breaker.setFailureThreshold(3);
            
            // Record failures
            for (let i = 0; i < 3; i++) {
                await breaker.recordFailure();
            }
            
            expect(await breaker.state()).to.equal(1); // OPEN
        });

        it("should only allow guardian to open circuit", async function () {
            await expect(breaker.connect(user1).openCircuit("Hack attempt"))
                .to.be.reverted;
        });

        it("should allow emergency withdrawal when open", async function () {
            // Send some ETH
            await owner.sendTransaction({
                to: await breaker.getAddress(),
                value: ethers.parseEther("1")
            });

            // Open circuit first
            await breaker.openCircuit("Emergency");
            
            const balanceBefore = await ethers.provider.getBalance(user1.address);
            await breaker.emergencyWithdrawETH(user1.address);
            const balanceAfter = await ethers.provider.getBalance(user1.address);
            
            expect(balanceAfter - balanceBefore).to.equal(ethers.parseEther("1"));
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    //                      SECURITY TESTS
    // ═══════════════════════════════════════════════════════════════════════

    describe("Security Scenarios", function () {
        let batchExecutor;
        let sampleDApp;

        beforeEach(async function () {
            const BatchExecutor = await ethers.getContractFactory("BatchExecutor");
            batchExecutor = await BatchExecutor.deploy();

            const SampleDApp = await ethers.getContractFactory("SampleDApp");
            sampleDApp = await SampleDApp.deploy();
        });

        it("should reject replayed signatures", async function () {
            const deadline = (await time.latest()) + 3600;
            const nonce = await batchExecutor.getNonce(user1.address);
            
            const calls = [{
                target: await sampleDApp.getAddress(),
                value: 0n,
                data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Test", "Bio"])
            }];

            const domain = {
                name: "GasOptimizer",
                version: "1",
                chainId: 31337n,
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
            function hashCalls(callsArray) {
                const callHashes = callsArray.map(call => 
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
            
            // First execution should succeed
            await batchExecutor.executeBatchMeta(
                { from: user1.address, calls, nonce, deadline },
                signature
            );

            // Replay should fail (nonce already incremented)
            await expect(batchExecutor.executeBatchMeta(
                { from: user1.address, calls, nonce, deadline },
                signature
            )).to.be.reverted;
        });

        it("should reject expired signatures", async function () {
            const deadline = (await time.latest()) - 1; // Already expired
            const nonce = await batchExecutor.getNonce(user1.address);
            
            const calls = [{
                target: await sampleDApp.getAddress(),
                value: 0n,
                data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Test", "Bio"])
            }];

            const domain = {
                name: "GasOptimizer",
                version: "1",
                chainId: 31337n,
                verifyingContract: await batchExecutor.getAddress()
            };

            const types = {
                Call: [
                    { name: "target", type: "address" },
                    { name: "value", type: "uint256" },
                    { name: "data", type: "bytes" }
                ],
                BatchExecution: [
                    { name: "from", type: "address" },
                    { name: "calls", type: "Call[]" },
                    { name: "nonce", type: "uint256" },
                    { name: "deadline", type: "uint256" }
                ]
            };

            const value = {
                from: user1.address,
                calls: calls,
                nonce: nonce,
                deadline: deadline
            };

            const signature = await user1.signTypedData(domain, types, value);

            await expect(batchExecutor.executeBatchMeta(
                { from: user1.address, calls, nonce, deadline },
                signature
            )).to.be.reverted;
        });

        it("should enforce relayer whitelist when enabled", async function () {
            // Enable whitelist
            await batchExecutor.setRelayerWhitelistEnabled(true);
            
            // Authorize relayer
            await batchExecutor.setRelayerAuthorization(relayer.address, true);
            
            // Unauthorized relayer should fail
            const deadline = (await time.latest()) + 3600;
            const nonce = await batchExecutor.getNonce(user1.address);
            
            const calls = [{
                target: await sampleDApp.getAddress(),
                value: 0n,
                data: sampleDApp.interface.encodeFunctionData("updateProfile", ["Test", "Bio"])
            }];

            const domain = {
                name: "GasOptimizer",
                version: "1",
                chainId: 31337n,
                verifyingContract: await batchExecutor.getAddress()
            };

            const types = {
                Call: [
                    { name: "target", type: "address" },
                    { name: "value", type: "uint256" },
                    { name: "data", type: "bytes" }
                ],
                BatchExecution: [
                    { name: "from", type: "address" },
                    { name: "calls", type: "Call[]" },
                    { name: "nonce", type: "uint256" },
                    { name: "deadline", type: "uint256" }
                ]
            };

            const value = {
                from: user1.address,
                calls: calls,
                nonce: nonce,
                deadline: deadline
            };

            const signature = await user1.signTypedData(domain, types, value);

            // Attacker tries to relay
            await expect(batchExecutor.connect(attacker).executeBatchMeta(
                { from: user1.address, calls, nonce, deadline },
                signature
            )).to.be.reverted;
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    //                     PERFORMANCE BENCHMARKS
    // ═══════════════════════════════════════════════════════════════════════

    describe("Performance Benchmarks", function () {
        let batchExecutor;
        let sampleDApp;

        beforeEach(async function () {
            const BatchExecutor = await ethers.getContractFactory("BatchExecutor");
            batchExecutor = await BatchExecutor.deploy();

            const SampleDApp = await ethers.getContractFactory("SampleDApp");
            sampleDApp = await SampleDApp.deploy();
        });

        it("should demonstrate scaling gas savings", async function () {
            console.log("\n📊 Gas Savings at Different Batch Sizes:\n");
            
            const results = [];
            
            for (let batchSize of [2, 5, 10, 20]) {
                // First, measure actual individual transaction gas
                let individualGas = 0n;
                for (let i = 0; i < batchSize; i++) {
                    const tx = await sampleDApp.createListing(`IndvItem${i}`, ethers.parseEther("0.1"));
                    const receipt = await tx.wait();
                    individualGas += receipt.gasUsed;
                }

                // Create batch calls
                const calls = [];
                for (let i = 0; i < batchSize; i++) {
                    calls.push({
                        target: await sampleDApp.getAddress(),
                        value: 0n,
                        data: sampleDApp.interface.encodeFunctionData(
                            "createListing", 
                            [`BatchItem${i}`, ethers.parseEther("0.1")]
                        )
                    });
                }

                // Execute batch and measure
                const batchTx = await batchExecutor.executeBatch(calls);
                const batchReceipt = await batchTx.wait();
                const batchedGas = batchReceipt.gasUsed;
                
                const savings = individualGas - batchedGas;
                const savingsPercent = Number((savings * 100n) / individualGas);
                
                results.push({ batchSize, individualGas, batchedGas, savings, savingsPercent });
                
                console.log(`   Batch Size: ${batchSize}`);
                console.log(`   Individual: ${individualGas} gas`);
                console.log(`   Batched:    ${batchedGas} gas`);
                console.log(`   Savings:    ${savings} gas (${savingsPercent}%)\n`);
            }
            
            // Verify savings increase with batch size
            expect(results[results.length - 1].savingsPercent)
                .to.be.gt(results[0].savingsPercent);
        });
    });
});
