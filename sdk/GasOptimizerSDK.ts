/**
 * Gas Optimizer SDK
 * 
 * TypeScript SDK for interacting with the Gas Fee Optimizer system.
 * Provides easy-to-use methods for:
 * - Building batched transactions
 * - Creating meta-transaction signatures
 * - Interacting with the relayer service
 * - Gas estimation and optimization
 */

import { ethers, Signer, Provider, TypedDataDomain, TypedDataField } from 'ethers';

// ═══════════════════════════════════════════════════════════════════════════
//                              TYPES
// ═══════════════════════════════════════════════════════════════════════════

export interface Call {
    target: string;
    value: bigint;
    data: string;
}

export interface BatchRequest {
    from: string;
    calls: Call[];
    nonce: bigint;
    deadline: number;
}

export interface ForwardRequest {
    from: string;
    to: string;
    value: bigint;
    gas: bigint;
    nonce: bigint;
    data: string;
}

export interface RelayerConfig {
    url: string;
    timeout?: number;
}

export interface GasOptimizerConfig {
    provider: Provider;
    signer?: Signer;
    batchExecutorAddress: string;
    forwarderAddress?: string;
    gasSponsorAddress?: string;
    relayer?: RelayerConfig;
    chainId?: bigint;
}

export interface GasEstimate {
    individualTotal: bigint;
    batchedTotal: bigint;
    savings: bigint;
    savingsPercent: number;
}

export interface RelayResult {
    success: boolean;
    transactionHash?: string;
    blockNumber?: number;
    gasUsed?: string;
    error?: string;
}

// ═══════════════════════════════════════════════════════════════════════════
//                              ABIS
// ═══════════════════════════════════════════════════════════════════════════

const BATCH_EXECUTOR_ABI = [
    "function executeBatch((address target, uint256 value, bytes data)[] calls) payable returns (bytes[])",
    "function executeBatchMeta((address from, (address target, uint256 value, bytes data)[] calls, uint256 nonce, uint256 deadline) request, bytes signature) returns (bytes[])",
    "function executeMetaTransaction(address from, address to, uint256 value, bytes data, uint256 nonce, uint256 deadline, bytes signature) returns (bytes)",
    "function getNonce(address account) view returns (uint256)",
    "function nonces(address) view returns (uint256)",
    "function DOMAIN_SEPARATOR() view returns (bytes32)",
    "function totalGasSaved() view returns (uint256)",
    "function totalBatchesExecuted() view returns (uint256)"
];

const FORWARDER_ABI = [
    "function execute((address from, address to, uint256 value, uint256 gas, uint256 nonce, bytes data) req, bytes signature) payable returns (bool, bytes)",
    "function executeBatch((address from, address to, uint256 value, uint256 gas, uint256 nonce, bytes data)[] reqs, bytes[] signatures) payable returns (bool[], bytes[])",
    "function verify((address from, address to, uint256 value, uint256 gas, uint256 nonce, bytes data) req, bytes signature) view returns (bool)",
    "function getNonce(address from) view returns (uint256)"
];

const GAS_SPONSOR_ABI = [
    "function checkEligibility(address user, uint256 requestedGas) view returns (bool, uint256)",
    "function config() view returns (bool, uint256, uint256, uint256, uint256)",
    "function userQuotas(address) view returns (uint256, uint256, uint256, bool)"
];

// ═══════════════════════════════════════════════════════════════════════════
//                           SDK CLASS
// ═══════════════════════════════════════════════════════════════════════════

export class GasOptimizerSDK {
    private provider: Provider;
    private signer?: Signer;
    private batchExecutor: ethers.Contract;
    private forwarder?: ethers.Contract;
    private gasSponsor?: ethers.Contract;
    private relayerConfig?: RelayerConfig;
    private chainId: bigint;

    private constructor(
        provider: Provider,
        signer: Signer | undefined,
        batchExecutor: ethers.Contract,
        forwarder: ethers.Contract | undefined,
        gasSponsor: ethers.Contract | undefined,
        relayerConfig: RelayerConfig | undefined,
        chainId: bigint
    ) {
        this.provider = provider;
        this.signer = signer;
        this.batchExecutor = batchExecutor;
        this.forwarder = forwarder;
        this.gasSponsor = gasSponsor;
        this.relayerConfig = relayerConfig;
        this.chainId = chainId;
    }

    /**
     * Create a new SDK instance
     */
    static async create(config: GasOptimizerConfig): Promise<GasOptimizerSDK> {
        const chainId = config.chainId || (await config.provider.getNetwork()).chainId;
        
        const signerOrProvider = config.signer || config.provider;
        
        const batchExecutor = new ethers.Contract(
            config.batchExecutorAddress,
            BATCH_EXECUTOR_ABI,
            signerOrProvider
        );

        let forwarder: ethers.Contract | undefined;
        if (config.forwarderAddress) {
            forwarder = new ethers.Contract(
                config.forwarderAddress,
                FORWARDER_ABI,
                signerOrProvider
            );
        }

        let gasSponsor: ethers.Contract | undefined;
        if (config.gasSponsorAddress) {
            gasSponsor = new ethers.Contract(
                config.gasSponsorAddress,
                GAS_SPONSOR_ABI,
                config.provider
            );
        }

        return new GasOptimizerSDK(
            config.provider,
            config.signer,
            batchExecutor,
            forwarder,
            gasSponsor,
            config.relayer,
            chainId
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        BATCH BUILDING
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Create a call object from contract method
     */
    createCall(
        contract: ethers.Contract,
        method: string,
        args: any[],
        value: bigint = 0n
    ): Call {
        return {
            target: contract.target as string,
            value,
            data: contract.interface.encodeFunctionData(method, args)
        };
    }

    /**
     * Create multiple calls from a list of operations
     */
    createCalls(
        operations: Array<{
            contract: ethers.Contract;
            method: string;
            args: any[];
            value?: bigint;
        }>
    ): Call[] {
        return operations.map(op => this.createCall(
            op.contract,
            op.method,
            op.args,
            op.value || 0n
        ));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      DIRECT EXECUTION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Execute a batch directly (user pays gas)
     */
    async executeBatch(calls: Call[], overrides?: ethers.Overrides): Promise<ethers.ContractTransactionResponse> {
        if (!this.signer) {
            throw new Error('Signer required for direct execution');
        }

        const totalValue = calls.reduce((sum, c) => sum + c.value, 0n);
        
        return this.batchExecutor.executeBatch(calls, {
            ...overrides,
            value: totalValue
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      META-TRANSACTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Get the current nonce for an address
     */
    async getNonce(address: string): Promise<bigint> {
        return this.batchExecutor.getNonce(address);
    }

    /**
     * Create an EIP-712 signature for a batch meta-transaction
     */
    async signBatchRequest(
        calls: Call[],
        deadline?: number
    ): Promise<{ request: BatchRequest; signature: string }> {
        if (!this.signer) {
            throw new Error('Signer required for signing');
        }

        const from = await this.signer.getAddress();
        const nonce = await this.getNonce(from);
        const actualDeadline = deadline || Math.floor(Date.now() / 1000) + 3600;

        // EIP-712 Domain
        const domain: TypedDataDomain = {
            name: 'GasOptimizer',
            version: '1',
            chainId: this.chainId,
            verifyingContract: this.batchExecutor.target as string
        };

        // Type definitions
        const types: Record<string, TypedDataField[]> = {
            Call: [
                { name: 'target', type: 'address' },
                { name: 'value', type: 'uint256' },
                { name: 'data', type: 'bytes' }
            ],
            BatchExecution: [
                { name: 'from', type: 'address' },
                { name: 'calls', type: 'Call[]' },
                { name: 'nonce', type: 'uint256' },
                { name: 'deadline', type: 'uint256' }
            ]
        };

        // Value to sign
        const value = {
            from,
            calls: calls.map(c => ({
                target: c.target,
                value: c.value,
                data: c.data
            })),
            nonce,
            deadline: actualDeadline
        };

        // Sign
        const signature = await this.signer.signTypedData(domain, types, value);

        return {
            request: {
                from,
                calls,
                nonce,
                deadline: actualDeadline
            },
            signature
        };
    }

    /**
     * Submit a signed batch via the relayer
     */
    async relayBatch(
        request: BatchRequest,
        signature: string
    ): Promise<RelayResult> {
        if (!this.relayerConfig) {
            throw new Error('Relayer not configured');
        }

        const response = await fetch(`${this.relayerConfig.url}/relay/batch`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                from: request.from,
                calls: request.calls.map(c => ({
                    target: c.target,
                    value: c.value.toString(),
                    data: c.data
                })),
                nonce: request.nonce.toString(),
                deadline: request.deadline,
                signature
            }),
            signal: AbortSignal.timeout(this.relayerConfig.timeout || 60000)
        });

        const result = await response.json();
        
        return {
            success: result.success,
            transactionHash: result.data?.transactionHash,
            blockNumber: result.data?.blockNumber,
            gasUsed: result.data?.gasUsed,
            error: result.error
        };
    }

    /**
     * Sign and relay a batch in one call
     */
    async signAndRelayBatch(
        calls: Call[],
        deadline?: number
    ): Promise<RelayResult> {
        const { request, signature } = await this.signBatchRequest(calls, deadline);
        return this.relayBatch(request, signature);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       GAS ESTIMATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Estimate gas for individual vs batched execution
     */
    async estimateGasSavings(calls: Call[]): Promise<GasEstimate> {
        // Base transaction cost
        const BASE_TX_COST = 21000n;
        
        // Estimate each call individually
        let individualTotal = 0n;
        for (const call of calls) {
            try {
                const estimate = await this.provider.estimateGas({
                    to: call.target,
                    data: call.data,
                    value: call.value
                });
                individualTotal += estimate + BASE_TX_COST;
            } catch {
                // Use a default estimate if call fails
                individualTotal += 100000n + BASE_TX_COST;
            }
        }

        // Estimate batched
        const batchedTotal = await this.batchExecutor.executeBatch.estimateGas(
            calls,
            { value: calls.reduce((sum, c) => sum + c.value, 0n) }
        );

        const savings = individualTotal - batchedTotal;
        const savingsPercent = Number((savings * 100n) / individualTotal);

        return {
            individualTotal,
            batchedTotal,
            savings,
            savingsPercent
        };
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       SPONSORSHIP
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Check if an address is eligible for gas sponsorship
     */
    async checkSponsorshipEligibility(
        address: string,
        gasAmount: bigint = 500000n
    ): Promise<{ eligible: boolean; sponsoredAmount: bigint }> {
        if (!this.gasSponsor) {
            return { eligible: false, sponsoredAmount: 0n };
        }

        const [eligible, sponsoredAmount] = await this.gasSponsor.checkEligibility(
            address,
            gasAmount
        );

        return { eligible, sponsoredAmount };
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         UTILITIES
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Encode a function call
     */
    encodeCall(abi: string[], method: string, args: any[]): string {
        const iface = new ethers.Interface(abi);
        return iface.encodeFunctionData(method, args);
    }

    /**
     * Decode a function result
     */
    decodeResult(abi: string[], method: string, data: string): ethers.Result {
        const iface = new ethers.Interface(abi);
        return iface.decodeFunctionResult(method, data);
    }

    /**
     * Get contract statistics
     */
    async getStats(): Promise<{
        totalGasSaved: bigint;
        totalBatchesExecuted: bigint;
    }> {
        const [totalGasSaved, totalBatchesExecuted] = await Promise.all([
            this.batchExecutor.totalGasSaved(),
            this.batchExecutor.totalBatchesExecuted()
        ]);

        return { totalGasSaved, totalBatchesExecuted };
    }

    /**
     * Get the contract addresses
     */
    getAddresses(): {
        batchExecutor: string;
        forwarder?: string;
        gasSponsor?: string;
    } {
        return {
            batchExecutor: this.batchExecutor.target as string,
            forwarder: this.forwarder?.target as string,
            gasSponsor: this.gasSponsor?.target as string
        };
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//                           HELPERS
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Create a batch builder for fluent API
 */
export class BatchBuilder {
    private calls: Call[] = [];

    add(target: string, data: string, value: bigint = 0n): BatchBuilder {
        this.calls.push({ target, value, data });
        return this;
    }

    addContractCall(
        contract: ethers.Contract,
        method: string,
        args: any[],
        value: bigint = 0n
    ): BatchBuilder {
        this.calls.push({
            target: contract.target as string,
            value,
            data: contract.interface.encodeFunctionData(method, args)
        });
        return this;
    }

    getCalls(): Call[] {
        return [...this.calls];
    }

    clear(): void {
        this.calls = [];
    }
}

export default GasOptimizerSDK;
