# AGENTS.md input snapshots

Run `bash scripts/sync-agents-md.sh` from the repository root to regenerate;
`bash scripts/sync-agents-md.sh --check` checks rendered bytes without writing.
Bash and standard Unix tools are sufficient; neither HOME nor a marketplace
checkout supplies inputs. Never hand-edit AGENTS.md.

Only standalone `@path` lines are imports, as in the upstream generator.
Inline references and load-on-demand tables remain prose. The complete eager
closure is verification-policy, critical-rules, and harness-workflow; these
snapshots have no further standalone imports. New recursive imports must ship
their sources too. Unreadable imports or recursion beyond five levels abort
before writing. Other `~/` imports are rejected instead of reading ambient HOME.

## Provenance

Captured 2026-09-20 for Task 430:

| Source | Repository input | SHA-256 at capture |
| --- | --- | --- |
| `ZenHive/claude-marketplace`, revision `9dad443e4bdcc0f8a566713b499afa0c3fbb9333`, `scripts/sync-agents-md.sh` | Exact upstream copy: `test/fixtures/agents/upstream-sync-agents-md.sh` | `ee88cd995b4c9da7b4e7206c80584dcbf73ca6902933f4af43a97c6aa3c80068` |
| Installed `~/.claude/includes/critical-rules.md` | `priv/agents/includes/critical-rules.md` | `8a24599a092433332cfdcd8004986c0949825d70263f789303811ca5302b2081` |
| Installed `~/.claude/includes/verification-policy.md` | `priv/agents/includes/verification-policy.md` | `6843473a65179908c28da6ce22649a9ce9d5da3ea88dfc1b23dd6df911d05b69` |
| Canonical harness source at revision `6211e63e76e2abff1afda71449670b89c8e87189`, reviewed Task 430 wording for the in-repo generator | `priv/includes/harness-workflow.md` (read directly, no duplicate) | `1dc5bf180881bcc8e99be09f2db694c6b274857ef62247791acf4d17f5bf396d` |

The generator was obtained from the installed marketplace cache checkout.
The installed include files had no upstream revision metadata; their exact
bytes are pinned here by content hash, without claiming an upstream revision.
The marketplace remains authoritative for other repositories. The vendored
script's header lists its deliberate resolver divergence; its generated banner
is retained for byte compatibility.

Before command-reference edits, both generators rendered the unchanged
CLAUDE.md (SHA-256 `b9d470197cd425d4b8c6432d26114dbbd542e8db2ef298b1e5d1dd33f5a70ca1`)
with identical pinned inputs to the committed AGENTS.md (SHA-256
`ee1638f275e4ce806de5c6eeb3035bd2f6ba5671851c6dcf1a46fa6476592213`).
The upstream run used a temporary HOME populated with these inputs; the vendored
run used an empty HOME. Both byte comparisons passed.

## Reviewed refreshes

Snapshot refreshes are explicit code-review changes: obtain the intended source
version, review its diff, copy every transitive dependency into this tree, and
record its origin and SHA-256 here. Update the upstream fixture and vendor header
when refreshing the generator. Edit harness-workflow at its canonical source.
Run `bash scripts/test-sync-agents-md.sh`, regenerate AGENTS.md, and run `--check`.
Commit the input changes, provenance, and generated result together. No hook or
command automatically refreshes these snapshots from HOME or the network.
