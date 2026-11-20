# BaseBasket Protocol (`BaseBasketRouter.sol`)
**Developed by Statera Inc.**

BaseBasket is a **100% stateless, non-custodial atomic execution router** on Base L2 (Chain ID: `8453`). It bundles multi-protocol DeFi 2.0 actions—including 0x swaps, Morpho Blue collateral deposits, and Aerodrome liquidity provision—into a single atomic transaction.

## Core Security Invariants
- **Zero Custody:** Holds zero user funds, LP tokens, or lending positions between blocks. All positions mint directly to `msg.sender`.
- **Zero Lingering Approvals:** Scoped ERC-20 approvals are granted before external calls and immediately reset to `0` (`forceApprove(spender, 0)`) in the same transaction.
- **Zero-Dust Sweeps:** All leftover input tokens, sweep tokens, and ETH deltas gained during execution are automatically refunded to `msg.sender`.
- **Onchain 3-Tier Fee Caps:** Enforces a maximum of `2.50%` (Standard), `0.75%` (Pro `>= $5,000`), and `0.25%` (Institutional `>= $100,000`).
- **Institutional Governance:** Target whitelisting (`setAllowedTarget`) is gated behind a **2-of-3 Safe Multi-Sig + 24-Hour TimelockController**, while emergency `pause()` is callable immediately by the Safe Guardian.
