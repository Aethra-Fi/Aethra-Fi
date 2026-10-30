"use client";

import { useCallback, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { BaseError, type Abi, type Address, type ContractFunctionArgs, type ContractFunctionName, type Hash } from "viem";
import { useAccount, usePublicClient, useSwitchChain, useWriteContract } from "wagmi";
import { CHAIN_ID } from "@/lib/network";

export type TxStatus = "idle" | "wallet" | "pending" | "success" | "error";

export interface TxState {
  status: TxStatus;
  hash: Hash | null;
  error: string | null;
}

/** Human message for a viem / wallet error. */
export function errorMessage(e: unknown): string {
  if (e instanceof BaseError) {
    const short = e.shortMessage || e.message;
    if (/user rejected|denied/i.test(short)) return "Request rejected in wallet.";
    const name = (e.walk((x) => typeof (x as { data?: { errorName?: string } }).data?.errorName === "string") as
      | { data?: { errorName?: string } }
      | null)?.data?.errorName;
    return name ? `Reverted: ${name}` : short;
  }
  return e instanceof Error ? e.message : String(e);
}

/**
 * Simulate → send → wait for a contract write. Invalidates all queries on success so balances refresh.
 * Usage: const tx = useTx(); tx.send({ address, abi, functionName, args })
 */
export function useTx() {
  const [state, setState] = useState<TxState>({ status: "idle", hash: null, error: null });
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient({ chainId: CHAIN_ID });
  const { address: account, chainId: walletChainId } = useAccount();
  const { switchChainAsync } = useSwitchChain();
  const qc = useQueryClient();

  const send = useCallback(
    async <const abi extends Abi, fn extends ContractFunctionName<abi, "nonpayable" | "payable">>(req: {
      address: Address;
      abi: abi;
      functionName: fn;
      args: ContractFunctionArgs<abi, "nonpayable" | "payable", fn>;
      value?: bigint;
    }) => {
      if (!client || !account) {
        setState({ status: "error", hash: null, error: "Connect a wallet first." });
        return null;
      }
      try {
        setState({ status: "wallet", hash: null, error: null });
        // the wallet may still be on the other network after the toggle
        if (walletChainId !== CHAIN_ID) await switchChainAsync({ chainId: CHAIN_ID });
        // simulate first for a readable revert reason
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const { request } = await client.simulateContract({ ...(req as any), account });
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const hash = await writeContractAsync(request as any);
        setState({ status: "pending", hash, error: null });
        const receipt = await client.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") throw new Error("Transaction reverted");
        setState({ status: "success", hash, error: null });
        void qc.invalidateQueries();
        return receipt;
      } catch (e) {
        setState((s) => ({ status: "error", hash: s.hash, error: errorMessage(e) }));
        return null;
      }
    },
    [client, account, walletChainId, switchChainAsync, writeContractAsync, qc],
  );

  const reset = useCallback(() => setState({ status: "idle", hash: null, error: null }), []);
  return { ...state, send, reset, busy: state.status === "wallet" || state.status === "pending" };
}
