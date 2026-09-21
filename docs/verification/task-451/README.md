# Revision-bound Insights evidence

Insights reads committed `roadmap/tasks.toml` from the registered roadmap repository,
and `CLAUDE.md`, `AGENTS.md` and `priv/includes/harness-workflow.md` from the registered
code repository. Each repository is pinned independently to its observed HEAD.
Only literal `docs/verification/` references in that roadmap are eligible repair
sources; supported suffixes are `.json`, `.md`, `.txt` and `.log`. Traversal paths,
symlinks, non-UTF-8 documents, missing files and blobs over 2 MB are unavailable.
Working files, includes outside Git, compressed recordings and arbitrary paths are
not read. No command or path supplied by the observer is executed.

A scan visits one additional registered project and the projects represented by
its bounded run/QA pages. Each project supplies at most 64 referenced repair
files. The reference catalog lists the references and limit; exceeding that limit
marks the pass partial. Dedicated QA attempts have their own 12-row cursor and
are rescanned for later outcomes, independently of implementation runs. Git
content/availability changes trigger consultation; unrelated commits do not.

The initial context contains 12 excerpts. Additional retained sources make the
pass conservatively partial even when their individual excerpts are complete. The observer can retrieve 20-entry
catalog pages, source continuations, older finding pages and a numbered task's
location in the retained roadmap. All source reads use pass-local immutable
snapshots, not a later Git read. The existing 32-read budget and consultation
deadline apply. Failed retrieval/publication does not consume the checkpoint;
unavailable or truncated evidence keeps the pass partial. Unchanged incomplete
scans do not invoke the AI. Finding revisions retain citation excerpts, hashes,
project, revision, provenance and availability across restarts.

Authority labels distinguish current intent/workflow from historical reports.
The observer judges whether actual repair/test evidence reconciles an existing
finding, retaining its exact id and history. Task status, merge ancestry and
operator assertions do not mechanically resolve findings. Focused dispatch,
full post-merge QA and intentional reviewer fix-and-approve remain separate.

## Verification

Focused offline checks:

```sh
mix test test/harness/insights --exclude integration
```

The added live test uses a real Codex observer with historical claim fixtures
identified explicitly as fixtures, and the repository's committed repair reports.
It does not read or update deployed findings. It requires an authenticated Codex
CLI and writes `.harness/task-451-live.json` for independent review. Tests verify
exact finding identity, retained history and literal revision-attributed citations;
the reviewer assesses the resulting reconciliation and remaining uncertainty.

```sh
mix test test/harness/insights/project_evidence_test.exs --include integration
```

Postgres tests require a separately created and migrated `harness_insights_*`
database. `postgres_test.exs` also contains an existing real observer test;
`restart_test.exs` restarts only its test-owned Repo process.

Recorded results and commands are in [checks.json](checks.json). The final real
observer response and 14 separately verified Git citations are in
[live.json](live.json). Earlier fixture failures and the live retrieval timeout
are recorded alongside their repairs and successful reruns.

Acceptance coverage:

- Inline-only repair commits: immutable project/revision/provenance sources,
  allowlist enforcement, symlink rejection and explicit unavailability tests.
- Exact finding reconciliation: retained historical revision, changed task intent,
  repair-only updates and real observer reconciliation of the three claim fixtures.
- Workflow authority: current intent overrides historical rollout requirements;
  the live assessment preserves non-reproduction and contradictory readback limits.
- Independent QA: a persisted running attempt changing to failed triggers a pass
  with zero changed runs; unchanged evidence avoids another consultation.
- Retrieval/persistence: catalog paging, task lookup, UTF-8 continuations, bounded
  reads, publication failure checkpoints and attributed citations after Repo restart.
- Live evidence: real tool-free Codex observations, literal citation validation
  against separately read Git blobs, and no changes to deployed findings or verdicts.
