import { useState } from "react";
import {
  useAccount,
  useChainId,
  usePublicClient,
  useReadContract,
} from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { erc20Abi, formatUnits, isAddress, parseUnits, type Address } from "viem";
import { agentCreditVaultAbi, agentCreditVaultFactoryAbi } from "./abi";
import { deployments } from "./config";
import { Addr, Empty, Hint, Loading, Shell, short, useTx } from "./ui";

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
  const dep = deployments[chainId] ?? {};
  const [vault, setVault] = useState<Address | "">("");

  return (
    <Shell
      title="Agent Credit Line"
      tagline="Lend USDC to an AI agent on your terms. You fund a vault you own, open a line for the agent's key with a borrow limit, an expiry and a due date, and every borrow, repayment and default is recorded publicly on-chain. No interest; optional flat fee."
      steps={[
        "Create a vault and deposit the USDC you are willing to lend.",
        "Open a line for an agent: max borrow, expiry, due date, optional destination allowlist.",
        "The agent borrows within the line. Anyone can repay on its behalf.",
        "Past the due date with debt left, anyone can mark a default on the public record.",
      ]}
      contractLabel="Vault factory"
      contractOf={(id) => deployments[id]?.factory}
      refs={[{ label: "USDC", address: dep.usdc }]}
      risk={
        <>
          <strong>Real funds.</strong> This contract is not audited. Lending to an agent is unsecured: if it does not
          repay, the only consequence is the public default record. Only deposit amounts you can afford to lose.
        </>
      }
    >
      {!isConnected && <Empty>Connect a wallet to create a vault, manage a line, or borrow and repay as an agent.</Empty>}

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
    </Shell>
  );
}

function VaultPicker(props: {
  owner: Address;
  factory?: Address;
  vault: string;
  setVault: (v: Address | "") => void;
}) {
  const { owner, factory, vault, setVault } = props;
  const { data: vaults, refetch, isLoading } = useReadContract({
    address: factory,
    abi: agentCreditVaultFactoryAbi,
    functionName: "vaultsOf",
    args: [owner],
    query: { enabled: !!factory },
  });
  const { writeContractAsync, status, run, safe } = useTx();
  return (
    <div className="card">
      <h2>1. Choose a vault</h2>
      <p className="muted">A vault is your own lending contract. It holds the USDC you deposit and enforces each agent's line. Each wallet can own several.</p>
      <div className="field-label">Your vaults on this network</div>
      {!factory ? (
        <Empty>No factory on this network, so vaults cannot be listed or created here.</Empty>
      ) : isLoading ? (
        <Loading>Looking up your vaults…</Loading>
      ) : vaults && vaults.length > 0 ? (
        <div className="row">
          {vaults.map((v) => (
            <button key={v} className={v === vault ? "seg seg-on" : "seg"} aria-pressed={v === vault} onClick={() => setVault(v)}>
              <code>{short(v)}</code>
              <span className="seg-sub">{v === vault ? "selected" : "select"}</span>
            </button>
          ))}
        </div>
      ) : (
        <Empty>This wallet has no vaults yet. Create one below, or paste the address of a vault you want to inspect.</Empty>
      )}
      <div className="row">
        <button
          disabled={!factory}
          onClick={safe(async () => {
            if (
              await run("Create vault", () =>
                writeContractAsync({ address: factory!, abi: agentCreditVaultFactoryAbi, functionName: "createVault" }),
              )
            ) {
              const r = await refetch();
              const list = r.data ?? [];
              if (list.length) setVault(list[list.length - 1]);
            }
          })}
        >
          Create new vault
        </button>
        <label>
          Or open a vault by address
          <input value={vault} placeholder="0x…" spellCheck={false} onChange={(e) => setVault(e.target.value.trim() as Address)} />
        </label>
      </div>
      {vault && !isAddress(vault) && <div className="bad muted">That is not a valid address (0x followed by 40 hex characters).</div>}
      <Hint>“Create new vault” deploys a vault contract owned by your connected wallet. One transaction, gas only — no funds move.</Hint>
      {status}
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
  const { writeContractAsync, status, run, safe } = useTx();
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
      <h2>2. Vault funding and settings (owner)</h2>
      <dl className="dl">
        <dt>Vault</dt>
        <dd>
          <Addr value={vault} full />
        </dd>
        <dt>Owner</dt>
        <dd>
          <Addr value={owner} /> {isOwner && <span className="ok">(you)</span>}
        </dd>
        <dt>Available to lend</dt>
        <dd>{usdcFmt(usdcBal)} USDC</dd>
        <dt>Outstanding</dt>
        <dd>
          {usdcFmt(totalPrincipal)} USDC principal + {usdcFmt(totalFeeOwed)} USDC fees
        </dd>
        <dt>Borrow fee</dt>
        <dd>{feeBps !== undefined ? `${Number(feeBps) / 100}% flat` : "…"}</dd>
        <dt>Borrowing</dt>
        <dd>{paused === undefined ? "…" : paused ? <span className="bad">Paused</span> : <span className="ok">Active</span>}</dd>
      </dl>
      {owner && address && !isOwner && (
        <div className="info">
          You are not the owner of this vault, so the owner buttons in sections 2 and 3 are disabled. You can still
          borrow as an agent or repay in section 4.
        </div>
      )}
      <h3>Liquidity</h3>
      <div className="row">
        <label>
          Deposit USDC
          <input value={usdcAmt} onChange={(e) => setUsdcAmt(e.target.value)} />
        </label>
        <button
          disabled={!usdc || !isOwner}
          onClick={safe(async () => {
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
          })}
        >
          Deposit
        </button>
        <button
          className="ghost"
          disabled={!usdc || !isOwner || !address}
          onClick={safe(async () => {
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
          })}
        >
          Withdraw unused
        </button>
      </div>
      <Hint>
        Deposit asks twice: approve exactly this amount of USDC, then move it from your wallet into the vault, where
        agents with a line can borrow it. Withdraw returns USDC that is not currently lent out to your wallet, and
        works even while paused.
      </Hint>
      <h3>Fee and pause</h3>
      <div className="row">
        <label>
          Flat fee (bps, 0–1000)
          <input value={fee} onChange={(e) => setFee(e.target.value)} />
        </label>
        <button
          disabled={!isOwner}
          onClick={safe(async () => {
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
          })}
        >
          Set fee
        </button>
        <button
          className="danger"
          disabled={!isOwner}
          onClick={safe(async () => {
            if (await run(paused ? "Unpause" : "Pause", () =>
              writeContractAsync({
                address: vault,
                abi: agentCreditVaultAbi,
                functionName: paused ? "unpause" : "pause",
              }),
            ))
              refresh();
          })}
        >
          {paused ? "Unpause borrowing" : "Pause borrowing"}
        </button>
      </div>
      <Hint>
        The fee is a one-off charge in basis points (100 = 1%, max 1000) added to the agent's debt on each new
        borrow; changing it does not touch existing debt. Pause stops all new borrows on this vault; repayments and
        your withdrawals keep working.
      </Hint>
      {status}
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
  const { writeContractAsync, status, run, safe } = useTx();
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
      <p className="muted">
        The agent is the key that will borrow (for example your bot's wallet). Enter its address to see its current
        line and public record.
      </p>
      <div className="row">
        <label>
          Agent address
          <input value={agent} placeholder="0x…" spellCheck={false} onChange={(e) => setAgent(e.target.value.trim())} />
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
        <button disabled={!isOwner || !validAgent} onClick={safe(open)}>
          Open / update line
        </button>
        <button
          className="danger"
          disabled={!isOwner || !validAgent}
          onClick={safe(async () => {
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
          })}
        >
          Revoke agent
        </button>
        <button
          className="ghost"
          disabled={!isOwner || !validAgent}
          onClick={safe(async () => {
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
          })}
        >
          Clear default
        </button>
      </div>
      {agent && !validAgent && <div className="bad muted">The agent address is not a valid address.</div>}
      <Hint>
        “Open / update line” is one transaction and moves no funds: it lets this agent borrow up to{" "}
        {cap || "0"} USDC in total until the expiry ({expiryDays || "0"} days), with everything due back in{" "}
        {dueDays || "0"} days. “Revoke agent” cuts off further borrowing and wipes its allowlist; existing debt and
        the public record stay. “Clear default” only works after the line is fully repaid and lets the agent borrow
        again.
      </Hint>
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
            onClick={safe(async () => {
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
            })}
          >
            Set recipient
          </button>
        </div>
      )}
      {allowlist && (
        <Hint>
          With the allowlist on, the agent can only send borrowed USDC to addresses you allow here, one transaction
          per address. Until you add one, it cannot borrow anywhere.
        </Hint>
      )}
      {validAgent && line && <LineSummary line={line as Line} usdc={usdc} vault={vault} agent={agent as Address} />}
      {status}
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
  if (!line.active && line.maxBorrow === 0n && line.principal === 0n && (!record || record.borrowCount === 0))
    return <Empty>No line has been opened for this agent on this vault.</Empty>;
  return (
    <dl className="dl" style={{ margin: "8px 0 12px" }}>
      <dt>Line status</dt>
      <dd>
        {line.active ? <span className="ok">Active</span> : <span className="bad">Revoked / not open</span>}
        {line.defaulted && <span className="bad"> · Defaulted</span>}
      </dd>
      <dt>Limit</dt>
      <dd>
        {usdcFmt(line.maxBorrow)} USDC · {usdcFmt(credit)} USDC available now
      </dd>
      <dt>Debt</dt>
      <dd>
        {usdcFmt(due)} USDC (principal {usdcFmt(line.principal)} + fee {usdcFmt(line.feeOwed)})
      </dd>
      <dt>Borrow until</dt>
      <dd>{ts(line.expiry)}</dd>
      <dt>Repay by</dt>
      <dd>{ts(line.dueDate)}</dd>
      <dt>Allowlist</dt>
      <dd>{line.allowlistEnabled ? "On — listed destinations only" : "Off — any destination"}</dd>
      <dt>Public record</dt>
      <dd>
        Borrowed {usdcFmt(record?.totalBorrowed)} · repaid {usdcFmt(record?.totalRepaid)} · {record ? Number(record.borrowCount) : "…"}{" "}
        borrows · {record ? Number(record.repayCount) : "…"} repayments ·{" "}
        <span className={record && Number(record.defaultCount) > 0 ? "bad" : ""}>
          {record ? Number(record.defaultCount) : "…"} defaults
        </span>
        {record && record.lastDefaultAt > 0n ? ` (last ${ts(record.lastDefaultAt)})` : ""}
      </dd>
    </dl>
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
  const { writeContractAsync, status, run, safe } = useTx();
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
          <input value={agent} placeholder="0x…" spellCheck={false} onChange={(e) => setAgent(e.target.value.trim())} />
        </label>
        <button className="ghost" disabled={!address} onClick={() => setAgent(address ?? "")}>
          Use my wallet
        </button>
      </div>
      {valid && line && <LineSummary line={line as Line} vault={vault} agent={agent as Address} usdc={usdc} />}
      <h3>Borrow (agent key only)</h3>
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
          onClick={safe(async () => {
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
          })}
        >
          Borrow
        </button>
      </div>
      <Hint>
        Sends {borrowAmt || "0"} USDC from the vault to the “Borrow to” address and adds{" "}
        {quote ? usdcFmt(quote[1]) : "…"} USDC to this agent's debt (fee {quote ? usdcFmt(quote[0]) : "…"} USDC). The
        memo is stored on-chain. It only succeeds when signed by the agent's own key, within its limit and before
        expiry.
      </Hint>
      <h3>Repay or mark default</h3>
      <div className="row">
        <label>
          Repay amount (USDC)
          <input value={repayAmt} onChange={(e) => setRepayAmt(e.target.value)} />
        </label>
        <button
          disabled={!usdc || !valid}
          onClick={safe(async () => {
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
          })}
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
          onClick={safe(async () => {
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
          })}
        >
          Mark default
        </button>
      </div>
      <Hint>
        Repay asks twice: approve exactly this amount, then pay it from your wallet toward this agent's debt
        (overpayment is capped at what is owed). Anyone can repay.
      </Hint>
      <Hint tone="danger">
        “Mark default” works for anyone once the due date has passed with debt remaining. It adds a default to the
        agent's public record, which cannot be erased, and blocks new borrows until the owner clears it.
      </Hint>
      <h3>Recent activity</h3>
      {!valid && <Empty>Enter an agent address to see its activity.</Empty>}
      {valid && logs.isLoading && <Loading>Loading recent events…</Loading>}
      {valid && logs.isError && (
        <div className="tx tx-error">
          <span className="tx-body">Could not load events from the RPC. Balances above are still live; try again shortly.</span>
        </div>
      )}
      {logs.data && logs.data.borrowed.length + logs.data.repaid.length + logs.data.defaulted.length === 0 && (
        <Empty>No borrow, repay or default events for this agent in the last ~49,000 blocks (about a day on Base).</Empty>
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
                  <td>
                    {row.block?.toString()} {row.hash && <Addr value={row.hash} kind="tx" copy={false} />}
                  </td>
                  <td>{row.kind}</td>
                  <td>{row.amount !== undefined ? usdcFmt(row.amount) : ""}</td>
                  <td>{row.details}</td>
                </tr>
              ))}
          </tbody>
        </table>
      )}
      {status}
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
