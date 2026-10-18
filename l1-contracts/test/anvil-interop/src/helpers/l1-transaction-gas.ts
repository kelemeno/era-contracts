import { ethers } from "ethers";
import { ETHEREUM_L1_TX_GAS_LIMIT } from "../core/const";

/**
 * The L1 gas rules the harness runs under, from `L1_GAS_RULES`. The default, "osaka", sends and asserts every L1
 * tx within EIP-7825's cap. "amsterdam" is a measurement mode for an Amsterdam L1 anvil (`ANVIL_BIN`): there
 * EIP-8037 state gas lets `tx.gas` exceed the cap, so txs declare their estimate and the cap is checked post hoc
 * on the execution-gas part.
 */
export const L1_GAS_RULES: "osaka" | "amsterdam" = readL1GasRules();

function readL1GasRules(): "osaka" | "amsterdam" {
  const rules = process.env.L1_GAS_RULES?.trim() || "osaka";
  if (rules !== "osaka" && rules !== "amsterdam") {
    throw new Error(`L1_GAS_RULES must be "osaka" or "amsterdam", got "${rules}"`);
  }
  return rules;
}

/** Gas overrides for an L1 tx: `osakaGasLimit` under "osaka", ethers' own estimate under "amsterdam". */
export function l1GasOverrides(osakaGasLimit: ethers.BigNumberish): { gasLimit?: ethers.BigNumberish } {
  return L1_GAS_RULES === "amsterdam" ? {} : { gasLimit: osakaGasLimit };
}

export type L1TransactionGasContext = {
  phase: "prepare" | "governance" | "chain-upgrade";
  bundle: string;
  index: number;
  target: string;
};

export type L1TransactionGasRecord = L1TransactionGasContext & {
  transactionHash: string;
  gasLimit: number;
  gasUsed: number;
};

type GasReceipt = Pick<ethers.providers.TransactionReceipt, "status" | "transactionHash" | "gasUsed">;

export function checkL1TransactionGas(
  receipt: GasReceipt,
  gasLimit: ethers.BigNumberish,
  context: L1TransactionGasContext
): L1TransactionGasRecord {
  const label = `${context.phase} ${context.bundle} tx ${context.index} (to ${context.target})`;
  if (receipt.status !== 1) {
    throw new Error(`${label}: transaction ${receipt.transactionHash} did not succeed`);
  }
  const declared = ethers.BigNumber.from(gasLimit);
  if (L1_GAS_RULES === "osaka" && declared.gt(ETHEREUM_L1_TX_GAS_LIMIT)) {
    throw new Error(`${label}: gas limit ${declared} exceeds Ethereum L1 cap ${ETHEREUM_L1_TX_GAS_LIMIT}`);
  }
  if (L1_GAS_RULES === "osaka" && receipt.gasUsed.gt(ETHEREUM_L1_TX_GAS_LIMIT)) {
    throw new Error(`${label}: gas used ${receipt.gasUsed} exceeds Ethereum L1 cap ${ETHEREUM_L1_TX_GAS_LIMIT}`);
  }
  return {
    ...context,
    transactionHash: receipt.transactionHash,
    gasLimit: declared.toNumber(),
    gasUsed: receipt.gasUsed.toNumber(),
  };
}

export function recordL1TransactionGas(
  receipt: GasReceipt,
  gasLimit: ethers.BigNumberish,
  context: L1TransactionGasContext
): void {
  const record = checkL1TransactionGas(receipt, gasLimit, context);
  console.log(`  L1 transaction gas: ${JSON.stringify(record)}`);
}
