# Hardware & Deployment Target — Migrating harness off the Laptop

> Durable record of an adjudicated decision. **Do not re-derive this analysis.**
> Cite it. Re-open only if one of the invalidation triggers at the bottom fires.
>
> Investigated 2026-08-23. Operator is based in Kuala Lumpur, MY; the target
> server is a Hetzner dedicated box in Germany.

## Decision

**Migrate harness onto the operator's existing Hetzner EX63 (SSH alias
`blockwatch-one`, hostname `ex63-eth`). Buy nothing. Use XFS reflinks for
worktree cloning — not VDO, not dedup, not a new machine.**

Three questions were on the table, all settled:

1. Build a Linux server locally in KL, or rent? — **Neither. The box already
   exists and is 80% idle.**
2. XFS + VDO for worktree dedup? — **No. Reflink already does the job,
   for free, and `dm-vdo` isn't even available on the target kernel.**
3. Is the existing box big enough? — **Yes, with room to spare.**

## The Target Server (measured 2026-08-23, not spec-sheet)

Hetzner EX63, Ubuntu 24.04.4 LTS, kernel 6.8. Public IP deliberately omitted —
this repo is public; host details live in the operator's SSH config.

| | |
|---|---|
| CPU | Intel Core Ultra 7 265 — 20 cores (8 P + 12 E), no SMT, max 4.8 GHz |
| RAM | 64 GB DDR5, **non-ECC** |
| Swap | 32 GB (unused) |
| Disks | 4× 3.84 TB Samsung PM9A3 (enterprise NVMe, power-loss protection) |
| Load at survey | 0.26 — reth + lighthouse together well under one core |

### Existing workload

An Ethereum node (reth execution + lighthouse consensus), no staking. A
Postgres-based ETH indexing project was planned on this box and **abandoned** —
it left behind a nearly empty 2.8 TB mirrored volume and a running Postgres
18.6, both of which harness now inherits.

### Storage layout as found

| Device | Size | FS | Mount | Used |
|---|---|---|---|---|
| md127 (RAID0, nvme0+nvme2) | 7.0 TB | XFS | `/data/reth` | 2.9 TB |
| md128 (**RAID1**, nvme1p4+nvme3p1) | 2.8 TB | XFS | `/data/postgresql` | **20 GB** |
| nvme3n1p2 | 783 GB | XFS | `/data/lighthouse` | 34 GB |
| vg0 (LVM on nvme1p3) | 400 GB | ext4 | `/`, `/home`, swap | 168 GB free in VG |

**`reflink=1` is already set on all three XFS volumes.** No reformat needed.

## Why the RAM Is Not the Constraint It Appears to Be

`free -h` reports 13 GB used / 42 GB buff-cache and invites the wrong
conclusion. The breakdown from `/proc/<pid>/status`:

| Process | RssAnon (hard) | RssFile (mmap, evictable) |
|---|---|---|
| reth | 5.8 GB | 20.3 GB (MDBX) |
| lighthouse | 6.2 GB | 0.2 GB |

Only **~12 GB is genuinely committed**. reth's 20 GB is its memory-mapped MDBX
database, which the kernel reclaims under pressure — reth then pays higher
random-read latency, it does not OOM.

**Budget: ~32–36 GB for harness, leaving reth ~16 GB of MDBX working set.
That supports 5–6 concurrent runs** (per run: BEAM + compile ~2 GB, dialyzer
peak 3–4 GB).

## Why Reflink, Not VDO

The thing worth deduplicating is N worktrees carrying near-identical `deps/`
and `_build/`. Two ways to get there:

- **XFS reflink** — copy-on-write at clone time. `git worktree add`, then
  reflink the `deps/` and `_build/` trees from a warm base checkout. Zero dedup
  index, zero CPU tax per write.
- **VDO** — block-level dedup applied *after the fact*, paying RAM for the
  dedup index, CPU per write, and added latency, against a workload that is
  millions of small `.beam` writes.

Reflink wins on merit. It also wins on availability: `dm-vdo` landed in
mainline 6.9, the target runs 6.8, and Ubuntu does not ship it.

**What reflink actually buys — not what it looks like.** It does *not* remove a
cold compile: `Harness.Worktree.warm/2` already copies `deps/`, `_build/` and
`priv/plts` into every run's worktree on every dispatch, on every platform. The
bytes already land. Reflink turns that existing ~331 MB-per-run byte copy into a
metadata operation — same result, near-zero time and near-zero space.

**🚨 Blocker: harness cannot produce a reflink on Linux today.**
`Worktree.clone_copy/2` shells out to `cp -cR` — the *macOS* clonefile flag. GNU
coreutils rejects `-c` outright, so every Linux warm operation falls through to
`File.cp_r`, a full byte copy. Measured: `File.cp_r` 0.74 s / 250 MiB written vs
`cp --reflink=auto -R` 0.12 s / 4 MiB. The fix is an OS branch on the flag
(`--reflink=auto` on Linux, `-c` on Darwin); until it lands, an XFS `reflink=1`
volume changes nothing about harness's disk usage.

**Constraint: the warm base checkout and the worktrees must live on the same
filesystem, or the reflink silently degrades to a full copy.** This is the real
reason the worktree root cannot stay on `/home` — that is ext4 on vg0, which has
no reflink support at all. Relocate with `HARNESS_WORKTREE_ROOT`
(`config/runtime.exs`); the compiled-in default under `~/_DATA/worktrees` is
laptop-shaped.

Independent of VDO: **never put Postgres on a dedup layer** — write
amplification plus latency.

## Rent vs. Build — Priced 2026-08-23, and Why It's Moot

Kept because the numbers explain *why* "use what you have" is the answer, and
because a future session will otherwise re-price this.

Hetzner raised dedicated prices on 2026-06-15. Net of VAT (a Malaysian customer
pays net):

| Model | CPU | RAM | €/mo | Setup |
|---|---|---|---|---|
| AX42-1 | Ryzen 7 PRO 8700GE, 8C | 64 GB ECC | 97.30 | 49 |
| AX102-1 | Ryzen 9 7950X3D, 16C | 128 GB ECC | 257.30 | 129 |
| AX162-1 | EPYC 9454P, 48C | 128 GB ECC reg. | 612.30 | 304 |

Contabo, no setup fee: Ryzen 9 7900 12C / 64 GB / 1 TB NVMe ≈ €96/mo; +128 GB
≈ €141/mo. Caveat — Contabo's "ODECC" on the Ryzen box is DDR5 **on-die** ECC,
which every DDR5 module has. It is not end-to-end ECC.

**Self-build died on the DRAM market.** As of August 2026, DDR5 is up ~485% in
twelve months on HBM/AI allocation; a 128 GB consumer kit runs ~$3,399 and
32 GB ECC UDIMM ~$350/module. A 128 GB ECC self-build lands near RM 12,600
capex before power and cooling — and in KL, a ~250 W box needs 24/7 aircon,
which roughly triples the marginal power bill. Forecast is "well above 2024
levels for at least another 18 months."

**Corollary worth keeping:** RAM is now the pricing axis, not CPU. Size
concurrency against memory first. Renting is currently arbitrage on hardware
the provider bought pre-spike — an advantage that erodes with each provider
refresh.

## Recommended Layout

Base and worktrees on md128 (RAID1, reflink, 2.8 TB free):

```
/data/postgresql/          <- md128, RAID1, reflink=1
├── 18/main/               <- Postgres 18.6 (already running)
├── harness/base/          <- warm checkout with deps/ + _build/
└── harness/worktrees/     <- cp --reflink=always from base
```

The mount point name is misleading for this use — bind-mount to `/data/harness`
or remount md128 at `/data/big`. Cosmetic, not a blocker.

Protect the node from build spikes with systemd slices rather than discipline:

```
# harness.slice
MemoryHigh=34G
MemoryMax=44G
IOWeight=50

# reth.service
MemoryLow=16G      # shielded from reclaim
IOWeight=200
```

`MemoryLow` on reth is the load-bearing setting — it preserves the MDBX cache
when harness runs a dialyzer peak. With 20 cores and ~50 GB elastic, this is
belt-and-braces rather than necessity.

## Migration Checklist

Installed: `git` 2.43, `cargo` 1.98, Postgres 18.6, `claude`
(`~/.local/bin/claude`).

- [x] Erlang/OTP + Elixir per `.tool-versions` via `asdf` (`mise` was tried and
      abandoned — it re-extracts over a manual OTP relocation, so `code_server`
      never starts)
- [x] Node (several agent CLIs need it)
- [x] `codex`, `cursor-agent`, `grok` CLIs
- [x] **Authenticate each agent CLI headlessly** — subscription OAuth on a box
      with no browser is the real migration work, not the hardware
- [x] Dedicated system user for harness (`harness`, uid 1002), deliberately
      **not** in the sudo group: `ethereum` holds `NOPASSWD: ALL` and owns the
      node's data dirs and `jwt.hex`, so running harness there would hand every
      dispatched agent passwordless root over the Ethereum node
- [x] `harness_prod` database + migrations. The node runs **`MIX_ENV=dev`**
      (systemd drop-in `harness.service.d/10-mix-env.conf`): this is an
      operator-only box behind a forward-only SSH tunnel, and Tidewave is
      `only: [:dev, :test]`, so a prod build would have no `/tidewave/mcp` —
      the very surface the operator drives the node from. `runtime.exs` honours
      `HARNESS_DATABASE_URL` in every env, so the dev build still uses
      `harness_prod`. `mix.exs` sets `start_permanent: Mix.env() != :test` so
      the systemd restart net survives the dev switch — under the old
      `== :prod` a crashed supervision tree left a live-but-dead BEAM that
      `Restart=` never noticed.
- [x] Worktree root off ext4 via `HARNESS_WORKTREE_ROOT`
- [ ] Verify reflink end-to-end (`filefrag -v` → `shared` extents, `df` delta) —
      **blocked on the `cp -cR` fix above**; verify with `filefrag`/`df`, never
      with `du`, which counts blocks per inode and so reports a *successful*
      reflink at full size
- [x] systemd slices above — and read the effective value from
      `/sys/fs/cgroup/...`, not `systemctl show`: a parent slice at
      `memory.low = 0` clamps the child to nothing while `systemctl show`
      cheerfully reports the configured number
- [x] Reach the dashboard (4018) over the existing forward-only SSH tunnel — a
      fifth `permitopen` on the same restricted key that already carries the ETH
      RPC ports, plus a `LocalForward` in the operator's `blockwatch-one-rpc`
      block. No public port, no new access path, and no Tailscale: the server
      already runs WireGuard, and the operator's tailnet does not include it

## Accepted Risks

- **non-ECC RAM.** Real but small factor across long compile runs. Pre-existing
  decision; harness does not worsen it.
- **reth on RAID0** (md127). No redundancy — a node is resyncable. Pre-existing.
- **Postgres and worktree build IO share md128.** harness's Postgres is small
  (Oban jobs, run records); contention is not expected to matter.

## Invalidation Triggers

Re-open this analysis if any becomes true:

- Concurrency demand exceeds ~6 parallel runs (RAM becomes binding first)
- The Ethereum node is decommissioned — frees ~12 GB committed, ~20 GB cache,
  2.9 TB, and all of its IO; the box then needs no compromises at all
- DRAM prices normalize toward 2024 levels, reviving the self-build option
- The target is reinstalled on a kernel ≥ 6.9 with a distro shipping `dm-vdo`
  (still would not change the reflink recommendation)
