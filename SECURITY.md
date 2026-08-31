# Security review (DroidSplit v0.2)

Reviewed against the v0.1 draft. v0.2 patches every issue that could move funds to the wrong person or lock them with no exit. This is not a paid audit. Do not deploy mainnet value until a third party has reviewed the frozen bytecode.

## Critical (fixed)

### 1. HashMatch paid on a caller-chosen word
`claim(..., evidenceHash, ...)` compared `evidenceHash == bounty.target`. The target is public. Anyone could pass the same bytes32 and take the reward without producing a file.

**Fix:** HashMatch removed. Only `Preimage` remains: `keccak256(preimage) == target`. APK-sized artifacts cannot fit in a transaction; those bounties must use `Optimistic`.

### 2. AttestN counted duplicate addresses
The same attested wallet repeated N times satisfied the check.

**Fix:** Nested uniqueness check, hard cap 32 attestors, duplicate reverts.

### 3. Optimistic challenge with zero votes paid the claimant
`yesBond >= noBond` made `0 >= 0` true. A junk claim plus an ignored challenge still paid out.

**Fix:** If `yesBond + noBond == 0`, refund both bonds and reopen. Ties also reopen. Claimant wins only on a *strict* majority.

### 4. Vote capital was seized by claimant/challenger
Voters had no payout path. `reclaimVote` zeroed their record and sent nothing.

**Fix:** Function removed. Dispute value is accounted to the winning *party* (claimant or challenger). Voting is now explicitly a way to back a side, not a pool you withdraw from. Empty/tie votes are refunded or sent to the public epoch pool so they are not stuck.

## High (fixed)

### 5. Publisher could reset the 7-day split clock forever
Each `proposeSplit` wrote `pendingSince = block.timestamp`.

**Fix:** Clock starts on the first proposal and does not reset.

### 6. Anyone could pulse any library onto any app
A publisher could farm the usage pool by pointing pulses at their own lib.

**Fix:** App publisher calls `lockDeps` once. Pulses may only score locked dependencies.

### 7. Expired commits trapped NAME_STAKE
Unrevealed commits had no reclaim.

**Fix:** `reclaimCommit` after `COMMIT_WINDOW`.

### 8. “Burn” on disputes was not burned
`loserPool / 10` was omitted from credits and sat in the contract forever.

**Fix:** That slice is added to the current usage epoch pool.

## Medium (fixed or accepted)

### 9. Install attestations were free
Sybil wallets could mint `AttestN` power for gas only.

**Fix:** `attestInstall` costs `0.001` BDAG and has a 1-day cooldown. Still sybil-able if the attacker pays. `AttestN` is only as strong as that fee.

### 10. Split rounding dust
Integer division could leave 1–15 wei in the contract per `pay`.

**Fix:** Last recipient receives the remainder.

### 11. Self-challenge
Claimant could challenge themselves to game bonds.

**Fix:** `msg.sender == claimant` reverts.

### 12. Zero registry
Constructor now rejects `address(0)`.

## Accepted risks (cannot be removed without an admin)

| Risk | Why it stays |
|---|---|
| Optimistic bounties are a capital game | Chain cannot read an APK or a bug report. A whale can out-vote a true challenge. |
| AttestN is pay-to-sybil | No trusted Play Integrity oracle is wired in. An oracle would be an admin. |
| Name-stake on a successful reveal is locked | Anti-squat. There is no owner to refund it. |
| Attest fees sit in the registry | Registry does not know DroidSplit. Treating them as a sink avoids a privileged forwarder. |
| Epoch dust | `distributeEpoch` uses `pool * score / total` per lib. A few wei can remain if you never pay a lib with leftover. |
| First-claim of package names | Commit–reveal stops most sniping; it does not stop someone revealing a name you wanted. |
| Publisher can delay `lockDeps` / freeze | Payments before freeze go 100% to the current publisher. Collaborators should not send value until `frozen == true`. |
| Handover has no timeout | Current publisher can overwrite a pending handover. Recipient should accept promptly. |
| No pause | A live bug cannot be frozen. Next version is a new deploy. Users opt in by using the new address. |
| `withdraw` to a contract that reverts | That user’s funds stay pending until they `withdrawTo` an EOA. Other users are unaffected. |

## Invariants to test before deploy

1. `address(droidSplit).balance >= sum(pending) + openBountyRewards + activeBonds + sum(undistributed epochPool residual)`.
2. After every `pay`, `sum(credits) == msg.value`.
3. A `Preimage` bounty cannot be claimed with `evidenceHash` alone.
4. Duplicate attestors revert.
5. Zero-vote `finalize` on a disputed bounty does not pay the reward.
6. `proposeSplit` twice does not move `pendingSince`.
7. `pulse` on a lib that is not a locked dep reverts.
8. `reclaimCommit` after reveal reverts; after window without reveal returns the stake once.

## Threats this code does not cover

- RPC / explorer confusion on BlockDAG (multiple public endpoints exist). Confirm chain id `1404` and the bytecode on the explorer you trust.
- Compromised publisher keys.
- Phishing sites that wrap these contracts.
- Compiler bugs in the solc you use. Pin `0.8.26` and verify the exact metadata.

## Verification

Publish this repo. After deploy, verify both contracts with the same compiler settings:

- solc `0.8.26`
- optimizer off unless you turn it on in this repo and commit that choice
- constructor arg for `DroidSplit` = registry address
