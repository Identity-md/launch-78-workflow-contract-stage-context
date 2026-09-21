# Streamline

Linear token streams on Sepolia. A sender funds a stream of **STRM** to a recipient over a
duration; the recipient withdraws whatever has accrued at any time; the sender can cancel, which
pays the recipient the accrued part and returns the unaccrued part to the sender.

Two contracts, both in `src/`:

| Contract               | Role                                                      |
| ---------------------- | --------------------------------------------------------- |
| `Streamline` (STRM)    | Fixed-supply ERC-20 reward token, zero-argument constructor |
| `StreamingVault`       | The streaming application contract, constructed with the token address |

ABIs for both are exported to `docs/abi/Streamline.json` and `docs/abi/StreamingVault.json`.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

All three run fully offline. `forge-std` is vendored as ordinary files under `lib/forge-std`
(v1.9.6, tracked content extracted with `git archive`, no submodule and no nested repository), so
nothing is fetched at build time. There is no other dependency.

`ffi` is disabled and no filesystem permissions are granted, so tests cannot reach the host. The
compiler is pinned by version (`solc_version = "0.8.26"`), never by path to an executable.

## Streamline (STRM)

- Name `Streamline`, symbol `STRM`, `decimals = 18`.
- `totalSupply` is a **compile-time constant** of `1_000_000_000 * 10**18` = 10^27 minor units, not
  a storage slot. The supply is fixed by the bytecode rather than by the absence of a caller
  authorised to change it.
- The zero-argument constructor credits the whole supply to `msg.sender` and emits
  `Transfer(address(0), msg.sender, totalSupply)`. At launch `msg.sender` is the project factory,
  which is the only address the factory can check its own balance against.
- There is no mint, burn, owner, minter, pause, blocklist, upgrade or rescue path, and no function
  that can create or destroy a balance. `transfer`/`transferFrom` conserve the sum of all balances
  exactly and move precisely the amount requested — no fee on transfer, no rebasing.
- `transferFrom` always decreases the allowance, including `type(uint256).max`. An "infinite"
  approval is infinite only in size; a spender's recorded allowance and what it can actually spend
  never disagree.
- `approve` **sets** rather than increments, per ERC-20. Reducing a live allowance is subject to the
  usual ERC-20 front-running caveat: set it to zero first, then to the new value.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`; it is not a proxy and cannot
  be made one.

## StreamingVault

### Constructor

```solidity
constructor(address token_)
```

Nonpayable. Stores `token_` as an `immutable` and reverts on the zero address. It makes no external
calls and moves no tokens, so it cannot disturb the launch supply the factory is holding while it
runs. This is the **only** constructor argument, supplied as `$token` by the manifest.

### State and roles

There is no owner, admin, fee, fee recipient, treasury, pause, guardian or upgrade path — no
privileged role exists in the bytecode, so none can be granted by a constructor argument. The only
addresses a stream ever answers to are its own `sender` and `recipient`. The deployer and the launch
factory have no more authority over the vault than any other address.

The vault never holds a balance of its own. Every token it holds is owed to the participants of some
live stream, and it has no function that can move tokens except on behalf of one.

### Entry conditions — `createStream(recipient, deposit, duration) → streamId`

Callable by anyone who has first `approve`d the vault for at least `deposit`. Reverts when:

| Condition | Error |
| --- | --- |
| `recipient == address(0)` | `RecipientIsZeroAddress` |
| `recipient == msg.sender` | `RecipientIsSender` |
| `recipient == address(vault)` | `RecipientIsVault` |
| `deposit == 0` | `DepositIsZero` |
| `duration == 0` | `DurationIsZero` |
| `duration > MAX_DURATION` (3650 days) | `DurationTooLong` |
| approval or balance short | `Streamline.InsufficientAllowance` / `InsufficientBalance` |

Stream ids are 1-based and strictly increasing, so `0` is never a stream. Streams start
immediately (`startTime = block.timestamp`); there is no scheduled or future start.

`MAX_DURATION` bounds the `deposit * elapsed` product in the accrual math and rejects what is far
likelier to be a units mistake than an intent.

### Accrual and withdrawal

`accrued(t) = deposit * (t - startTime) / (stopTime - startTime)`, clamped to `0` before `startTime`
and to exactly `deposit` at or after `stopTime`. Multiplication happens before division, so the
elapsed fraction is not truncated away; the remaining integer truncation rounds **down**, in the
sender's favour by at most one minor unit, and the recipient recovers it at `stopTime`, where
`deposit` is returned without any division.

- `withdraw(streamId, amount)` — recipient only, `amount > 0`, `amount <= withdrawableAmount`.
- `withdrawMax(streamId)` — recipient only, takes everything accrued and unpaid; reverts
  `NothingToWithdraw` if that is zero.
- When cumulative withdrawals reach `deposit`, the stream becomes `Completed` and `StreamCompleted`
  is emitted. A completed stream accepts no further withdrawals and cannot be cancelled.

Accrual uses `block.timestamp`. A proposer's few seconds of timestamp leeway moves an accrued
balance by `deposit * seconds / duration`, which is immaterial for any sane duration and is not a
value anyone can bias in their favour across a whole stream. **No part of this protocol derives
randomness**, from timestamps or anything else, so no verifiable-randomness mechanism is needed or
present; there is no lottery, auction or draw here.

### Cancellation, timeouts and refunds

`cancel(streamId)` — **sender only**, active streams only. The recipient is paid `accrued -
withdrawn`, the sender is refunded `deposit - accrued`, the stream becomes `Cancelled`, accrual
freezes at that instant, and `StreamCancelled` is emitted with both amounts.

Only the sender may cancel. That asymmetry is what makes a stream worth receiving: the recipient
can never lose what has already accrued, and the sender can never reclaim it. The recipient does not
need a cancel of their own — withdrawing everything accrued is always available to them, and they
have no unaccrued part to reclaim.

There is no timeout, no expiry and no deadline after which a stream changes hands. A stream past its
`stopTime` simply sits at `accrued == deposit` until the recipient withdraws; nobody else can ever
claim it, and it cannot be swept. Cancellation settles both legs in the same transaction, so no
balance is parked in the vault for a later claim step. If either leg's token transfer fails, the
whole cancellation reverts — a settlement that pays one party and silently drops the other is the
one outcome worse than not cancelling.

### Events

Every state change emits: `StreamCreated`, `Withdrawn`, `StreamCompleted`, `StreamCancelled`.
`streamId`, `sender` and `recipient` are indexed so the site can filter by participant. Views
`getStream`, `accruedAmount`, `withdrawableAmount`, `refundableAmount`, `sentStreamIds` and
`receivedStreamIds` let a frontend list and price streams without replaying logs.

### Reentrancy and call surface

The vault's only external counterparty is the single immutable token. It follows
checks-effects-interactions unconditionally — state is final before any `transfer`/`transferFrom` —
and additionally holds a `nonReentrant` latch on all three state-changing functions, so a token with
a callback is rejected rather than merely harmless. Both properties are tested against a malicious
token that re-enters `createStream`, `withdraw`, `withdrawMax` and `cancel`.

`token.transfer`/`transferFrom` return values are checked strictly; a `false` return reverts
`TokenTransferFailed`. There are no payable functions, so ETH sent to the vault reverts. There is no
`DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in either runtime.

## Assumptions

These are the things the code takes for granted. `Streamline` satisfies all of them; a reviewer
pairing this vault with a different token should re-check each one.

1. **The token moves exactly what it is asked to.** `createStream` credits the stream with `deposit`
   without measuring the balance delta. A fee-on-transfer, rebasing or deflationary token would
   leave the vault short and the last withdrawal from a stream would revert. `Streamline` transfers
   exact amounts and the project floor asserts this against the attested bytecode.
2. **Transfers cannot be blocked.** Cancellation pushes tokens to both parties. A token with a
   blocklist or a transfer hook could make a stream uncancellable. `Streamline` has neither.
3. **The token does not re-enter.** Not relied upon — see above — but stated because the guarantee
   comes from the vault, not the token.
4. **No supply above ~3.7e68 minor units.** `deposit * elapsed` is bounded by
   `deposit * MAX_DURATION`; beyond that it would revert rather than wrap. STRM's 10^27 is nine
   orders of magnitude clear of the bound.
5. **Per-participant id arrays grow without bound.** `sentStreamIds`/`receivedStreamIds` append on
   creation. The appending sender pays for it, but an address with an enormous number of streams
   will eventually be unable to read its own list in one `eth_call`. Frontends should fall back to
   `StreamCreated` logs at that scale.
6. **Custody.** The vault holds other people's STRM for the life of a stream. Nothing here is a
   security audit — see below.

## Deployment parameters

Sepolia, chain id `11155111`, launched through `ProjectFactory` under Sepolia policy v3.

- `bytecode_hash = "none"` as the policy requires. `cbor_metadata = false` is set too, so the
  deployed runtime is code only: the project floor's opcode scan steps over `PUSH` immediates but
  not over an appended metadata blob, where a stray `0xF4`/`0xFF` byte would read as a forbidden
  opcode.
- `evm_version = "cancun"`, optimizer on, 200 runs. Pinned so the offline verifier compiles exactly
  what was tested.
- Runtime sizes: `Streamline` ≈ 1.3 KiB, `StreamingVault` ≈ 4.5 KiB. Both far inside EIP-170.
- Launch token: `Streamline`, zero constructor arguments.
- Application contract: `StreamingVault`, one argument, the token address, which the manifest must
  pass as `$token`. It must **not** be a hard-coded address.
- `$owner` is not used and must not be added: the vault has no owner parameter and no privileged
  role for one to fill. Nothing in either contract reads `msg.sender` in a constructor, so the
  factory being `msg.sender` at launch confers nothing.
- Dependency order: `Streamline` before `StreamingVault`.
- Pool (from the launch reference, not a valuation claim): no hook, paired against native ETH
  (zero address), fee `3000`, tickSpacing `60`, initial price
  `79228162514264337593543950336` (sqrtPriceX96), seeded with the launch token only.

### Unresolved deployment choices

Not this assignment's to decide, and left for the manifest and review nodes:

- The identifier `StreamingVault` uses for the manifest's application-contract list. It is within
  the 32-ASCII-character limit and is not the reserved `MerkleDistributor`, but the manifest node
  owns the name.
- `MAX_DURATION` is fixed in the bytecode at 3650 days. If the protocol wants longer streams, that
  is a source change, not a deployment parameter.
- How much of the 10^27 supply the deployer directs to the liquidity pool versus retains. No
  contract here constrains it.

## Operational responsibilities

- **This assignment implements and tests the contracts only.** It does not write `launch.json`, does
  not publish source, does not build the website, holds no key, broadcasts no transaction and
  authorises none. The admitted release goes through the deployer on Sepolia.
- **A passing test suite is not a security audit.** This vault custodies other people's STRM. An
  independent adversarial review of the contracts *and* the manifest — permissions, privileged
  beneficiaries, `msg.sender` in constructors, dependency order, payout and refund accounting,
  every argument that grants a role — is required before release, and a second review after the
  site.
- Reviewers: the manifest is where a privileged argument would be smuggled in, and this vault's
  defence is that there is no role for one to fill. Confirm that `StreamingVault`'s single argument
  is `$token` and that no `$owner` has been introduced.
- Once deployed, nothing about either contract can be changed, paused or migrated. There is no
  operator role to staff and no upgrade to plan.

## Protected suites

The delivered `forge test` is self-contained: it reads no environment variable and will never be
made to depend on one.

The separate `evm_project` floor suites are run by the verifier, not from this tree, and are
configured entirely through the environment:

| Variable | Used for |
| --- | --- |
| `IMD_TOKEN_CREATION_CODE` | `Streamline` creation code; the token suite skips when empty |
| `IMD_TOKEN_DECIMALS` | Cross-check against the manifest's decimals (18) |
| `IMD_PROJECT_FACTORY` | Address the factory is etched at, and the deployer of record |
| `IMD_PROJECT_CHAIN_ID` | `11155111` for Sepolia |
| `IMD_EXPECTED_TOKEN` | Predicted token address |
| `IMD_EXPECTED_SUPPLY` | `1000000000000000000000000000` (10^27) |
| `IMD_PROJECT_COUNT` | `1` — this launch has a single application contract |
| `IMD_PROJECT_CODE_0` | `StreamingVault` creation code, token address argument appended |
| `IMD_PROJECT_SALT_0` | CREATE2 salt for it |
| `IMD_PROJECT_ADDRESS_0` | Its predicted address |

## Test coverage

`test/Streamline.t.sol` and `test/StreamingVault.t.sol`; mocks in `test/mocks/`. Between them:
fixed supply and the absence of every common admin selector; exact-amount transfers and allowance
accounting; conservation of funds across create, withdraw and cancel; linear accrual at the
boundaries (`startTime`, mid-stream, `stopTime`, long after); unauthorised callers on every
function; duplicate and repeated actions; withdrawals of zero, of more than accrued, and after
completion or cancellation; cancellation before any accrual and after full accrual; settlement
failure through a token that returns `false`; and reentrancy through a malicious token on all four
entry points.
