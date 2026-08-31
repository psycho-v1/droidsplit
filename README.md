# DroidSplit

Ownerless protocol for Android publishers, library payouts, and automatic bounties.

Target chain: BlockDAG mainnet, EVM chain id `1404`.

No admin key. No proxy. No pause. Source is this repository.

## Contracts

| File | What it does |
|---|---|
| `contracts/PublisherRegistry.sol` | Commit-reveal names, APK hashes, locked deps, paid install attestations |
| `contracts/DroidSplit.sol` | Splits, usage pool, bounties, pull vault |
| `contracts/PullVault.sol` | Pending balances |

Read [SECURITY.md](SECURITY.md) before sending value.

## Deploy

1. `PublisherRegistry` (no constructor args)
2. `DroidSplit(registry)`
3. Verify both on the explorer
4. There is no owner function to call after that

Suggested compiler: solc 0.8.26, optimizer off.

Confirm the RPC and explorer yourself. This ecosystem has had more than one public endpoint. Chain id must be 1404.

## Use

**Register an app**

1. `registerPublisher(uri)`
2. `commit(keccak256(abi.encodePacked(uint8(1), keccak256(bytes(packageName)), salt, you)))` with 0.01 native
3. Wait 1 hour, `revealApp` within 24 hours
4. `lockDeps(appId, libIds)` once

If you miss the reveal window: `reclaimCommit`.

**Payments**

- `proposeSplit` then wait 7 days, anyone `freezeSplit`
- Until freeze, `pay` credits 100% to the current publisher
- After freeze, `pay` splits by bps
- Recipients call `withdraw`

**Usage pool**

- Send native to `DroidSplit` or `fundEpoch`
- `pulse{value: 0.001 ether}(appId, libIds)` — libIds must be locked deps
- After the epoch, `distributeEpoch(epoch, libId)`

**Bounties**

- `Preimage` — claimant supplies bytes whose keccak256 equals target. Pays in the same tx.
- `AttestN` — N unique paid install attestations. Pays in the same tx.
- `Optimistic` — public evidence URI + bond. Unchallenged 3 days pays. Challenged goes to bond vote. No votes or a tie refunds bonds and reopens.
- `finalize(id)` is public.

## Push this to GitHub

From a machine logged into your GitHub account:

```
cd droidsplit
git remote add origin https://github.com/YOUR_USER/droidsplit.git
git branch -M main
git push -u origin main
```

Or:

```
gh repo create droidsplit --public --source=. --remote=origin --push
```

Do not put a private key in this repo. Deploy from your own wallet.

## License

MIT. See LICENSE.
