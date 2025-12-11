# KipuBank V3 – USDC‑Centric Vault with Uniswap V4

## High‑Level Overview

KipuBank V3 is a multi‑asset vault where every deposit is internally converted and tracked in **USDC**.  
Users can deposit USDC, any ERC‑20 supported by **Uniswap V4**, or native ETH, and the contract swaps non‑USDC assets to USDC via **Universal Router + Permit2**.

Compared to the original KipuBank:

- Balances are no longer held per raw token; the economic balance is always USDC (`usdcBalances`).
- The old `tokenToUsd`‑based caps used approximate prices; now limits rely on actual USDC amounts returned by swaps.
- The original access control, reporting (`totals`, `funds`), and Chainlink price utilities are preserved.

---

## Key Features vs Original Version

- **USDC‑only internal accounting**  
  All value is stored as USDC. Deposits in other tokens are swapped to USDC on arrival.  
  This simplifies limits, accounting, and auditability compared to the old multi‑token `funds[user][token]` model.

- **Generalized deposits via Uniswap V4**  
  - `deposit(usdc, amount)` handles direct USDC deposits.  
  - `depositArbitraryToken(tokenIn, amountIn, quotedUsdc, poolFee, tickSpacing)` swaps ERC‑20 → USDC (single‑hop).  
  - `depositEthForUsdc(quotedUsdc, poolFee, tickSpacing)` swaps ETH → USDC.  

- **Unified swap function**  
  A single internal function `_swapExactInputSingle` handles both ERC‑20 and ETH (using `address(0)` for native), building a V4 `PoolKey` and executing a `V4_SWAP` via Universal Router and Permit2.

- **Stronger caps**  
  - `userCapUsd`: per‑user USDC cap.  
  - `bankCapUsd`: global USDC cap for the whole vault.  
  The original per‑user cap logic is preserved conceptually, but now uses real USDC values instead of estimated USD.

- **Safer deposit surface**  
  Direct ETH transfers to the contract are rejected.  
  Users must call `depositEthForUsdc`, ensuring every meaningful deposit path goes through a USDC‑converting swap.

---

## Basic Usage (High Level)

- Deploy the contract providing:
  - Per‑withdrawal limit, per‑user cap, and global cap in USDC units (6 decimals).  
  - Addresses for Chainlink ETH/USD feed, USDC, Universal Router, Permit2, and the Uniswap V4 PoolManager.

- Users:
  - Approve USDC and call `deposit(usdc, amount)` for pure USDC deposits.  
  - Approve an ERC‑20 and call `depositArbitraryToken(...)` to deposit that token and be credited in USDC.  
  - Send ETH via `depositEthForUsdc(...)` to be credited in USDC.  
  - Withdraw using `withdrawUsdc(amount)` (recommended) or `withdraw(token, amount)` for legacy flows.

---

## Design Trade‑offs

- **Pros**  
  - Simpler risk limits and accounting (one asset of record: USDC).  
  - On‑chain swaps integrated directly into the vault.  
  - Clear separation between per‑user and global capacity.

- **Cons**  
  - Users cannot keep non‑USDC exposure inside the vault; all deposits become USDC.  
  - Only single‑hop routes are supported; no multi‑hop routing inside the contract.  
  - Configuration depends on correct Uniswap and Chainlink addresses per network.
