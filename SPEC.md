# Agent Credit Line - spec (prototype, 22 Nov 2026)

Source: overnight research in `agents-lending.md`. A loan version of in-house Agent Spend Controls.

**Problem.** Agents need to pay for APIs, compute and goods, but a grant (Spend Controls) gives money away. A loan needs a cap, a due date, repayment, and a public default record the owner can enforce. Official Aave/Morpho agent tools still make the owner sign every borrow.

**Users.** Builders floating a capped USDC line to a paying agent, and operators who want an on-chain repayment history per agent.

**Scope (v1, Ethereum and Base, after an audit and Lef's OK).** One owner-funded USDC vault (EOA or Safe). Per agent: max borrow, borrow expiry, repay-by due date, optional destination allowlist. `borrow` / `repay` (anyone may repay). Optional flat fee in bps, no interest. Pause, revoke, guardian. Public borrow/repay/default record; anyone may `markDefault` after the due date. Owner withdraws unused liquidity. Simple web dapp. Out: pooled lenders, interest, Aave yield, other tokens or chains, unsecured credit.

**Competitors.** Spend Controls (a grant). Aave for Agents and Morpho Agents (owner still signs): https://aave.com/agents https://agents.morpho.org. SOURCE (credit adapter unbuilt, Robinhood): https://source-protocol.app/. Priors (USDG on Robinhood, $5–$500): https://priors.trade/use. ERC-8460 draft ABI. 3Jane, Wildcat and Bond Credit are underwriting or ratings — too heavy for v1.

**Choices (for Lef to review).** USDC only. No interest; optional flat fee (0–10% bps, default 0) added to debt and repaid first. Fully owner-collateralized; no pooled lenders or Aave in v1. `dueDate` ≥ `expiry`; new borrows stop after either. Default is sticky until the owner clears it after full repayment; lifetime totals stay public. Allowlist is optional. Views `availableCredit`, `amountDue`, `quote` for later ERC-8460 alignment. Ownable2Step plus an optional guardian (pause/revoke only).
