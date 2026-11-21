import { useState } from "react";
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { erc20Abi, formatUnits, isAddress, parseUnits, type Address } from "viem";
import { agentCreditVaultAbi, agentCreditVaultFactoryAbi } from "./abi";
import { deployments } from "./config";

const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");
const usdcFmt = (v?: bigint) => (v === undefined ? "…" : formatUnits(v, 6));
const ts = (v?: bigint | number) => {
  const n = Number(v ?? 0);
  return n > 0 ? new Date(n * 1000).toLocaleString() : "—";
};

type Line = {
  active: boolean;
  allowlistEnabled: boolean;
  defaulted: boolean;
  expiry: bigint;
  dueDate: bigint;
  epoch: number;
  maxBorrow: bigint;
  principal: bigint;
  feeOwed: bigint;
};

type Record = {
  lastDefaultAt: bigint;
  borrowCount: number;
  repayCount: number;
  defaultCount: number;
  totalBorrowed: bigint;
  totalRepaid: bigint;
};

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, chains } = useSwitchChain();
  const dep = deployments[chainId] ?? {};
  const [vault, setVault] = useState<Address | "">("");

  return (
    <div className="wrap">
      <h1>Agent Credit Line</h1>
      <div className="muted">
        Owner-funded USDC credit lines for AI agents: max borrow, expiry, due date, optional allowlist,
        borrow/repay, pause, revoke, and a public default record. Prototype — not audited. Ethereum, Base
        and local anvil. No interest; optional flat fee.
      </div>

      <div className="card">
        <h2>Wallet</h2>
        {!isConnected ? (
          <div className="row">
            {connectors.map((c) => (
              <button key={c.uid} onClick={() => connect({ connector: c })}>
                Connect {c.name}
              </button>
            ))}
          </div>
        ) : (
          <div className="row">
            <span>
              Connected <code>{address}</code>
            </span>
            <button className="ghost" onClick={() => disconnect()}>
              Disconnect
            </button>
          </div>
        )}
        <div className="row">
          {chains.map((c) => (
            <button key={c.id} className={c.id === chainId ? "" : "ghost"} onClick={() => switchChain({ chainId: c.id })}>
              {c.name}
            </button>
          ))}
        </div>
        {!deployments[chainId] && <div className="warn">Unsupported chain: use Ethereum, Base or local anvil.</div>}
        {deployments[chainId] && !dep.factory && (
          <div className="warn">
            <strong>Not deployed yet</strong> on this chain — the factory address is empty. Core flows stay disabled until
            you deploy (<code>make deploy-mainnet</code> or <code>make deploy-base</code>), which writes the address into{" "}
            <code>web/src/deployments.json</code>. You can still paste an existing vault address below after connecting.
          </div>
        )}
        {deployments[chainId]?.live && dep.factory && (
          <div className="warn">
            Live chain with real funds. This contract is NOT audited — only deposit amounts you can afford to lose.
          </div>
        )}
      </div>

      {isConnected && address && (
        <>
          <VaultPicker owner={address} factory={dep.factory} vault={vault} setVault={setVault} />
          {vault && isAddress(vault) && (
            <>
              <VaultOverview vault={vault} usdc={dep.usdc} />
              <OwnerLine vault={vault} usdc={dep.usdc} />
              <AgentView vault={vault} usdc={dep.usdc} />
            </>
          )}
        </>
      )}
    </div>
  );
}

function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const [status, setStatus] = useState("");
  const run = async (label: string, fn: () => Promise<`0x${string}`>) => {
    try {
      setStatus(`${label}: confirm in wallet…`);
      const hash = await fn();
      setStatus(`${label}: pending ${short(hash)}`);
      await client!.waitForTransactionReceipt({ hash });
      setStatus(`${label}: confirmed ✓`);
      return true;
    } catch (e) {
      setStatus(`${label}: ${(e as Error).message.split("\n")[0]}`);
      return false;
    }
  };
  return { writeContractAsync, status, run };
}

function VaultPicker(props: {
  owner: Address;
  factory?: Address;
  vault: string;
  setVault: (v: Address | "") => void;
}) {
  const { owner, factory, vault, setVault } = props;
  const { data: vaults, refetch } = useReadContract({
    address: factory,
    abi: agentCreditVaultFactoryAbi,
    functionName: "vaultsOf",
    args: [owner],
    query: { enabled: !!factory },
  });
  const { writeContractAsync, status, run } = useTx();
  return (
    <div className="card">
      <h2>1. Vault</h2>
      {!factory && (
        <div className="warn">
          <strong>Not deployed yet.</strong> No factory address for this chain. Deploy first (see DEPLOY.md), or set
          VITE_FACTORY_* in web/.env.
        </div>
      )}
      <div className="row">
        <button
          disabled={!factory}
          onClick={async () => {
            if (
              await run("Create vault", () =>
                writeContractAsync({ address: factory!, abi: agentCreditVaultFactoryAbi, functionName: "createVault" }),
              )
            ) {
              const r = await refetch();
              const list = r.data ?? [];
              if (list.length) setVault(list[list.length - 1]);
            }
          }}
        >
          Create new vault
        </button>
        <label>
          Or use vault address
          <input value={vault} placeholder="0x…" onChange={(e) => setVault(e.target.value as Address)} />
        </label>
      </div>
      {vaults && vaults.length > 0 && (
        <div className="row">
          {vaults.map((v) => (
            <button key={v} className={v === vault ? "" : "ghost"} onClick={() => setVault(v)}>
              {short(v)}
            </button>
          ))}
        </div>
      )}
      <div className="muted">{status}</div>
    </div>
  );
}

function VaultOverview({ vault, usdc }: { vault: Address; usdc?: Address }) {
  const { data: usdcBal, refetch: refetchUsdc } = useReadContract({
    address: usdc,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [vault],
    query: { enabled: !!usdc },
  });
  const { data: paused, refetch: refetchPaused } = useReadContract({
    address: vault,
    abi: agentCreditVaultAbi,
    functionName: "paused",
  });
  const { data: owner } = useReadContract({ address: vault, abi: agentCreditVaultAbi, functionName: "owner" });
  const { data: feeBps, refetch: refetchFee } = useReadContract({
    address: vault,
    abi: agentCreditVaultAbi,
    functionName: "feeBps",
  });
  const { data: totalPrincipal } = useReadContract({
    address: vault,
    abi: agentCreditVaultAbi,
    functionName: "totalPrincipal",
  });
  const { data: totalFeeOwed } = useReadContract({
    address: vault,
    abi: agentCreditVaultAbi,
    functionName: "totalFeeOwed",
  });
  const { address } = useAccount();
  const { writeContractAsync, status, run } = useTx();
  const [usdcAmt, setUsdcAmt] = useState("100");
  const [fee, setFee] = useState("0");
  const isOwner = address && owner && address.toLowerCase() === owner.toLowerCase();

  const refresh = () => {
    refetchUsdc();
    refetchPaused();
    refetchFee();
  };

  return (
    <div className="card">
      <h2>2. Vault overview (owner)</h2>
      <div className="muted">
        Owner <code>{owner ? short(owner) : "…"}</code>
        {" · "}liquidity {usdcFmt(usdcBal)} USDC
        {" · "}outstanding {usdcFmt(totalPrincipal)} principal + {usdcFmt(totalFeeOwed)} fees
        {" · "}fee {feeBps !== undefined ? `${Number(feeBps) / 100}%` : "…"}
        {" · "}
        {paused ? <span className="bad">paused</span> : <span className="ok">active</span>}
      </div>
      <div className="row">
        <label>
          Deposit USDC
          <input value={usdcAmt} onChange={(e) => setUsdcAmt(e.target.value)} />
        </label>
        <button
          disabled={!usdc || !isOwner}
          onClick={async () => {
            if (!usdc) return;
            const amt = parseUnits(usdcAmt || "0", 6);
            if (
              await run("Approve USDC", () =>
                writeContractAsync({ address: usdc, abi: erc20Abi, functionName: "approve", args: [vault, amt] }),
              )
            ) {
              await run("Deposit", () =>
                writeContractAsync({ address: vault, abi: agentCreditVaultAbi, functionName: "deposit", args: [amt] }),
              );
              refresh();
            }
          }}
        >
          Deposit
        </button>
        <button
          className="ghost"
          disabled={!usdc || !isOwner || !address}
          onClick={async () => {
            const amt = parseUnits(usdcAmt || "0", 6);
            if (
              await run("Withdraw", () =>
                writeContractAsync({
                  address: vault,
                  abi: agentCreditVaultAbi,
                  functionName: "withdraw",
                  args: [address!, amt],
                }),
              )
            )
              refresh();
          }}
        >
          Withdraw unused
        </button>
      </div>
      <div className="row">
        <label>
          Flat fee (bps, 0–1000)
          <input value={fee} onChange={(e) => setFee(e.target.value)} />
        </label>
        <button
          disabled={!isOwner}
          onClick={async () => {
            if (
              await run("Set fee", () =>
                writeContractAsync({
                  address: vault,
                  abi: agentCreditVaultAbi,
                  functionName: "setFeeBps",
                  args: [Number(fee)],
                }),
              )
            )
              refresh();
          }}
        >
          Set fee
        </button>
        <button
          className="danger"
          disabled={!isOwner}
          onClick={async () => {
            if (await run(paused ? "Unpause" : "Pause", () =>
              writeContractAsync({
                address: vault,
                abi: agentCreditVaultAbi,
                functionName: paused ? "unpause" : "pause",
              }),
            ))
              refresh();
          }}
        >
          {paused ? "Unpause" : "Pause"}
        </button>
      </div>
      <div className="muted">{status}</div>
    </div>
  );
}

function OwnerLine({ vault, usdc }: { vault: Address; usdc?: Address }) {
  const { address } = useAccount();
  const { data: owner } = useReadContract({ address: vault, abi: agentCreditVaultAbi, functionName: "owner" });
  const isOwner = address && owner && address.toLowerCase() === owner.toLowerCase();
  const [agent, setAgent] = useState("");
  const [cap, setCap] = useState("1000");
  const [expiryDays, setExpiryDays] = useState("30");
  const [dueDays, setDueDays] = useState("60");
  const [allowlist, setAllowlist] = useState(false);
  const [recipient, setRecipient] = useState("");
  const [allowed, setAllowed] = useState(true);
  const { writeContractAsync, status, run } = useTx();
  const validAgent = isAddress(agent);

  const { data: line, refetch } = useReadContract({
    address: vault,
    abi: agentCreditVaultAbi,
    functionName: "getLine",
    args: validAgent ? [agent as Address] : undefined,
    query: { enabled: validAgent },
  });

  const open = async () => {
    const now = Math.floor(Date.now() / 1000);
    const expiry = BigInt(now + Number(expiryDays) * 86400);
    const due = BigInt(now + Number(dueDays) * 86400);
    if (
      await run("Open / update line", () =>
        writeContractAsync({
          address: vault,
          abi: agentCreditVaultAbi,
          functionName: "openLine",
          args: [agent as Address, parseUnits(cap || "0", 6), expiry, due, allowlist],
        }),
      )
    )
      refetch();
  };

  return (
    <div className="card">
      <h2>3. Open or update a line (owner)</h2>
      <div className="row">
        <label>
          Agent address
          <input value={agent} placeholder="0x…" onChange={(e) => setAgent(e.target.value)} />
        </label>
        <label>
          Max borrow (USDC)
          <input value={cap} onChange={(e) => setCap(e.target.value)} />
        </label>
        <label>
          Expiry (days from now)
          <input value={expiryDays} onChange={(e) => setExpiryDays(e.target.value)} />
        </label>
        <label>
          Due date (days from now)
          <input value={dueDays} onChange={(e) => setDueDays(e.target.value)} />
        </label>
      </div>
      <div className="row">
        <label>
          Destination allowlist
          <select value={allowlist ? "on" : "off"} onChange={(e) => setAllowlist(e.target.value === "on")}>
            <option value="off">Off — any destination</option>
            <option value="on">On — only listed addresses</option>
          </select>
        </label>
        <button disabled={!isOwner || !validAgent} onClick={open}>
          Open / update line
        </button>
        <button
          className="danger"
          disabled={!isOwner || !validAgent}
          onClick={async () => {
            if (
              await run("Revoke", () =>
                writeContractAsync({
                  address: vault,
                  abi: agentCreditVaultAbi,
                  functionName: "revokeAgent",
                  args: [agent as Address],
                }),
              )
            )
              refetch();
          }}
        >
          Revoke agent
        </button>
        <button
          className="ghost"
          disabled={!isOwner || !validAgent}
          onClick={async () => {
            if (
              await run("Clear default", () =>
                writeContractAsync({
                  address: vault,
                  abi: agentCreditVaultAbi,
                  functionName: "clearDefault",
                  args: [agent as Address],
                }),
              )
            )
              refetch();
          }}
        >
          Clear default
        </button>
      </div>
      {allowlist && (
        <div className="row">
          <label>
            Recipient
            <input value={recipient} placeholder="0x…" onChange={(e) => setRecipient(e.target.value)} />
          </label>
          <label>
            Allowed
            <select value={allowed ? "yes" : "no"} onChange={(e) => setAllowed(e.target.value === "yes")}>
              <option value="yes">Allow</option>
              <option value="no">Deny</option>
            </select>
          </label>
          <button
            disabled={!isOwner || !validAgent || !isAddress(recipient)}
            onClick={async () => {
              if (
                await run("Set recipient", () =>
                  writeContractAsync({
                    address: vault,
                    abi: agentCreditVaultAbi,
                    functionName: "setRecipient",
                    args: [agent as Address, recipient as Address, allowed],
                  }),
                )
              )
                refetch();
            }}
          >
            Set recipient
          </button>
        </div>
      )}
      {validAgent && line && <LineSummary line={line as Line} usdc={usdc} vault={vault} agent={agent as Address} />}
      <div className="muted">{status}</div>
    </div>
  );
}

function LineSummary({ line, vault, agent, usdc }: { line: Line; vault: Address; agent: Address; usdc?: Address }) {
  const { data: credit } = useReadContract({
    address: vault,
    abi: agentCreditVaultAbi,
    functionName: "availableCredit",
    args: [agent],
  });
  const { data: due } = useReadContract({
    address: vault,
    abi: agentCreditVaultAbi,
    functionName: "amountDue",
    args: [agent],
  });
  const { data: rec } = useReadContract({
    address: vault,
    abi: agentCreditVaultAbi,
    functionName: "getRecord",
    args: [agent],
  });
  const record = rec as Record | undefined;
  void usdc;
  return (
    <div className="muted" style={{ marginTop: 8 }}>
      {line.active ? <span className="ok">active</span> : <span className="bad">revoked / not opened</span>}
      {line.defaulted && (
        <>
          {" · "}
          <span className="bad">defaulted</span>
        </>
      )}
      {" · "}cap {usdcFmt(line.maxBorrow)} USDC
      {" · "}debt {usdcFmt(due)} (principal {usdcFmt(line.principal)} + fee {usdcFmt(line.feeOwed)})
      {" · "}available {usdcFmt(credit)}
      {" · "}expires {ts(line.expiry)} · due {ts(line.dueDate)}
      {" · "}allowlist {line.allowlistEnabled ? "on" : "off"}
      <div>
        Public record: borrowed {usdcFmt(record?.totalBorrowed)} · repaid {usdcFmt(record?.totalRepaid)} · borrows{" "}
        {record ? Number(record.borrowCount) : "…"} · repayments {record ? Number(record.repayCount) : "…"} · defaults{" "}
        {record ? Number(record.defaultCount) : "…"}
        {record && record.lastDefaultAt > 0n ? ` (last ${ts(record.lastDefaultAt)})` : ""}
      </div>
    </div>
  );
}

function AgentView({ vault, usdc }: { vault: Address; usdc?: Address }) {
  const { address } = useAccount();
  const [agent, setAgent] = useState(address ?? "");
  const [to, setTo] = useState("");
  const [borrowAmt, setBorrowAmt] = useState("10");
  const [repayAmt, setRepayAmt] = useState("10");
  const [memo, setMemo] = useState("job-1");
  const valid = isAddress(agent);
  const { writeContractAsync, status, run } = useTx();
  const client = usePublicClient();

  const { data: line, refetch } = useReadContract({
    address: vault,
    abi: agentCreditVaultAbi,
    functionName: "getLine",
    args: valid ? [agent as Address] : undefined,
    query: { enabled: valid },
  });
  const { data: due } = useReadContract({
    address: vault,
    abi: agentCreditVaultAbi,
    functionName: "amountDue",
    args: valid ? [agent as Address] : undefined,
    query: { enabled: valid },
  });
  const { data: quote } = useReadContract({
    address: vault,
    abi: agentCreditVaultAbi,
    functionName: "quote",
    args: [parseUnits(borrowAmt || "0", 6)],
  });

  const logs = useQuery({
    queryKey: ["credit-logs", vault, agent, client?.chain?.id],
    enabled: !!client && valid,
    queryFn: async () => {
      const toBlock = await client!.getBlockNumber();
      const fromBlock = toBlock > 49_000n ? toBlock - 49_000n : 0n;
      const [borrowed, repaid, defaulted] = await Promise.all([
        client!.getLogs({ address: vault, event: borrowEvent, args: { agent: agent as Address }, fromBlock, toBlock }),
        client!.getLogs({ address: vault, event: repayEvent, args: { agent: agent as Address }, fromBlock, toBlock }),
        client!.getLogs({ address: vault, event: defaultEvent, args: { agent: agent as Address }, fromBlock, toBlock }),
      ]);
      return { borrowed, repaid, defaulted };
    },
  });

  return (
    <div className="card">
      <h2>4. Borrow, repay, and public record</h2>
      <div className="row">
        <label>
          Agent
          <input value={agent} placeholder="0x…" onChange={(e) => setAgent(e.target.value)} />
        </label>
        <button className="ghost" disabled={!address} onClick={() => setAgent(address ?? "")}>
          Use my wallet
        </button>
      </div>
      {valid && line && <LineSummary line={line as Line} vault={vault} agent={agent as Address} usdc={usdc} />}
      <div className="row">
        <label>
          Borrow to
          <input value={to} placeholder="0x…" onChange={(e) => setTo(e.target.value)} />
        </label>
        <label>
          Amount (USDC)
          <input value={borrowAmt} onChange={(e) => setBorrowAmt(e.target.value)} />
        </label>
        <label>
          Memo
          <input value={memo} onChange={(e) => setMemo(e.target.value)} />
        </label>
        <button
          disabled={!isAddress(to) || !valid}
          onClick={async () => {
            const bytes32 = memoToBytes32(memo);
            if (
              await run("Borrow", () =>
                writeContractAsync({
                  address: vault,
                  abi: agentCreditVaultAbi,
                  functionName: "borrow",
                  args: [to as Address, parseUnits(borrowAmt || "0", 6), bytes32],
                }),
              )
            ) {
              refetch();
              logs.refetch();
            }
          }}
        >
          Borrow
        </button>
      </div>
      {quote && (
        <div className="muted">
          Quote: fee {usdcFmt(quote[0])} USDC, debt added {usdcFmt(quote[1])} USDC
        </div>
      )}
      <div className="row">
        <label>
          Repay amount (USDC)
          <input value={repayAmt} onChange={(e) => setRepayAmt(e.target.value)} />
        </label>
        <button
          disabled={!usdc || !valid}
          onClick={async () => {
            if (!usdc) return;
            const amt = parseUnits(repayAmt || "0", 6);
            if (
              await run("Approve USDC", () =>
                writeContractAsync({ address: usdc, abi: erc20Abi, functionName: "approve", args: [vault, amt] }),
              )
            ) {
              if (
                await run("Repay", () =>
                  writeContractAsync({
                    address: vault,
                    abi: agentCreditVaultAbi,
                    functionName: "repay",
                    args: [agent as Address, amt],
                  }),
                )
              ) {
                refetch();
                logs.refetch();
              }
            }
          }}
        >
          Repay (anyone)
        </button>
        <button
          className="ghost"
          disabled={!valid || !due}
          onClick={() => setRepayAmt(due ? formatUnits(due, 6) : repayAmt)}
        >
          Fill amount due
        </button>
        <button
          className="danger"
          disabled={!valid}
          onClick={async () => {
            if (
              await run("Mark default", () =>
                writeContractAsync({
                  address: vault,
                  abi: agentCreditVaultAbi,
                  functionName: "markDefault",
                  args: [agent as Address],
                }),
              )
            ) {
              refetch();
              logs.refetch();
            }
          }}
        >
          Mark default
        </button>
      </div>
      <h2 style={{ marginTop: 16 }}>Recent activity</h2>
      {logs.data && logs.data.borrowed.length + logs.data.repaid.length + logs.data.defaulted.length === 0 && (
        <div className="muted">No borrow, repay or default events in the last ~49k blocks.</div>
      )}
      {logs.data && (logs.data.borrowed.length > 0 || logs.data.repaid.length > 0 || logs.data.defaulted.length > 0) && (
        <table>
          <thead>
            <tr>
              <th>Block</th>
              <th>Event</th>
              <th>Amount</th>
              <th>Details</th>
            </tr>
          </thead>
          <tbody>
            {[
              ...logs.data.borrowed.map((l) => ({
                block: l.blockNumber,
                idx: l.logIndex,
                hash: l.transactionHash,
                kind: "Borrowed",
                amount: l.args.amount,
                details: `to ${short(l.args.to)} · fee ${usdcFmt(l.args.fee)} · debt ${usdcFmt(l.args.debt)}`,
              })),
              ...logs.data.repaid.map((l) => ({
                block: l.blockNumber,
                idx: l.logIndex,
                hash: l.transactionHash,
                kind: "Repaid",
                amount: l.args.amount,
                details: `from ${short(l.args.from)} · remaining ${usdcFmt(l.args.remainingDebt)}`,
              })),
              ...logs.data.defaulted.map((l) => ({
                block: l.blockNumber,
                idx: l.logIndex,
                hash: l.transactionHash,
                kind: "Defaulted",
                amount: l.args.debt,
                details: `by ${short(l.args.by)}`,
              })),
            ]
              .sort((a, b) => Number((a.block ?? 0n) - (b.block ?? 0n)) || (a.idx ?? 0) - (b.idx ?? 0))
              .reverse()
              .map((row) => (
                <tr key={`${row.hash}-${row.kind}-${row.idx}`}>
                  <td>{row.block?.toString()}</td>
                  <td>{row.kind}</td>
                  <td>{row.amount !== undefined ? usdcFmt(row.amount) : ""}</td>
                  <td>{row.details}</td>
                </tr>
              ))}
          </tbody>
        </table>
      )}
      <div className="muted">{status}</div>
    </div>
  );
}

const borrowEvent = {
  type: "event",
  name: "Borrowed",
  inputs: [
    { name: "agent", type: "address", indexed: true },
    { name: "to", type: "address", indexed: true },
    { name: "amount", type: "uint256", indexed: false },
    { name: "fee", type: "uint256", indexed: false },
    { name: "debt", type: "uint256", indexed: false },
    { name: "memo", type: "bytes32", indexed: false },
  ],
} as const;

const repayEvent = {
  type: "event",
  name: "Repaid",
  inputs: [
    { name: "agent", type: "address", indexed: true },
    { name: "from", type: "address", indexed: true },
    { name: "amount", type: "uint256", indexed: false },
    { name: "remainingDebt", type: "uint256", indexed: false },
  ],
} as const;

const defaultEvent = {
  type: "event",
  name: "Defaulted",
  inputs: [
    { name: "agent", type: "address", indexed: true },
    { name: "debt", type: "uint256", indexed: false },
    { name: "by", type: "address", indexed: true },
  ],
} as const;

function memoToBytes32(s: string): `0x${string}` {
  const hex = Array.from(new TextEncoder().encode(s.slice(0, 31)))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
    .padEnd(64, "0");
  return `0x${hex}`;
}
