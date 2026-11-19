# BuildersV4 subnet creator can freeze staker withdrawals via editSubnet (Morpheus, Base)

## Claim

`BuildersV4.editSubnet()` lets a subnet creator replace the whole `Subnet`
struct at any time after deposits (only the name is immutable). There is no
upper bound on `withdrawLockPeriodAfterDeposit` (`_validateSubnet` only
checks `>= minimalWithdrawLockPeriod`, 7 days live), and `withdraw()` reads
the lock LIVE from storage. Raising it to `1e30` seconds freezes every
staker's MOR until the creator lowers it again; raising it to
`type(uint128).max` makes the lock check itself overflow (panic 0x11).
V3 prevented this with the `editPoolDeadline` + `poolStart` guards
(`editBuilderPool` required `block.timestamp + editPoolDeadline <
poolStart`); V4 removed both, and V4 also removed the pause mechanism, so
there is no emergency withdraw. The freeze is reversible only by the
subnet creator — the victim has no self-service exit.

## Run

```bash
BASE_RPC_URL=<Base archive RPC URL> ./run.sh
```

Equivalent one-liner:

```bash
forge test --fork-url <BASE_RPC_URL> --fork-block-number 59534749
```

Fork: Base mainnet, block **59534749** (pinned). Dependencies are vendored
under `lib/` (forge-std, no submodules); no setup beyond an RPC URL.
No privileged protocol role is used: the "attacker" is a regular user who
created the subnet (permissionless, creation fee is 0 live).

## Expected output (5/5 PASS)

- `test_adminRaiseLocksVictimFunds`: control withdraw succeeds before the
  edit; after the edit (lock raised to 1e30) withdraw reverts
  `BU: user withdraw is locked` immediately and after +365 days; 950 MOR
  stays frozen (900 pre-edit + 50 deposited post-edit); the attacker
  cannot take the deposit via `withdraw()`.
- `test_maxLockPanicsButStillFreezes`: lock == `uint128.max` -> withdraw
  reverts (overflow panic) — same freeze, different revert reason.
- `test_adminCanReleaseSoItIsRansomLeverage`: lowering the lock restores
  withdrawals — the freeze is entirely at the creator's discretion.
- `test_onlyAdminCanEdit`: a stranger cannot edit the subnet.
- `test_liveConfig`: live `minimalWithdrawLockPeriod` is 604800 (7 days).

A passing run is logged in `output-fork-59534749.txt`.

## Economics

- Creator cost: ~0 (subnet creation free live) + gas for 2 txs.
- Creator direct profit: 0 (funds are locked, not taken).
- Victim impact: loss of access to the full deposit (950 MOR in the PoC;
  live, BuildersV4 holds ~3,002,169 MOR across subnets, of which
  ~1,906,177 MOR in third-party subnets; largest single third-party
  subnet Mordiem holds 747,725 MOR). The creator holds ransom leverage:
  funds release only if the creator lowers the lock.
- Live path: yes for the mechanics (permissionless `createSubnet`); the
  victim must voluntarily deposit into the creator's subnet (social layer:
  the creator picks an attractive name; names are unique per chain).
- Requires impersonation: no (the creator uses only their own role,
  obtained permissionlessly).

## Honest scope note

No subnet is frozen on mainnet today. Across all 15 historical
`SubnetEdited` events, every edit set a standard lock (7 days, or 30 days
for Lumerin) equal to the subnet's current lock — no abnormal lock was
ever set. In the 9 edits where the creation lock is also verified, the
edit set exactly the creation value; the other 6 edits (Lumerin,
MOR Phoenix Pool, MORDIEM, Own Your Mind x3) set the same standard lock
the subnet still has today. This PoC proves a latent capability plus live
third-party exposure, not an ongoing incident.
