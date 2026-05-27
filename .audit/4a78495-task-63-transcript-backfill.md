---
sha: 4a784950de089ac0ad8846e14aae364a454c1d46
short_sha: 4a78495
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: task 63 — dashboard transcript backfill on mount (seq-tagged broadcasts + shared 200 KiB buffer)

**Original commit:** 4a78495 — `harness: task 63 — dashboard transcript backfill on mount (seq-tagged broadcasts + shared 200 KiB buffer)`
**Author:** E.FU
**Files touched:** 10 (CHANGELOG.md, ROADMAP.md, lib/harness/dashboard/live.ex, lib/harness/dashboard/transcript.ex, lib/harness/run.ex, roadmap/data.json, roadmap/tasks.toml, test/harness/dashboard/live_test.exs, test/harness/dashboard/transcript_test.exs, test/harness/run_test.exs)
**LOC:** +414

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7 | bug (codex) | lib/harness/dashboard/live.ex:`handle_info({:harness_transcript, _, _, _}, _)` | `_run_id` is ignored — a stale PubSub message queued from a previously viewed run can append to the newly selected run's transcript after navigation. Codex reproduced locally with `Phoenix.PubSub` + `Harness.Dashboard.Live.handle_info/2`. | **Applied:** added a guard clause that drops broadcasts whose `run_id != socket.assigns.run_id` before the existing seq-dedup clauses. |
| 2 | 3 | doc-gap (codex) | lib/harness/agent_adapter/driver.ex:`on_output` docstring | Still references `Harness.Dashboard.Transcript.broadcast/2`; the new Run-owned threading sends `{:transcript_chunk, _}` to the gen_statem which then calls `broadcast/3`. | **Applied:** docstring now describes the generic 1-arity hook + names the current Run-consumer shape (`{:transcript_chunk, chunk}` → gen_statem → `broadcast/3`). |
| 3 | — | acceptance | — | Opening a run detail page mid-run backfills via `Run.transcript/1`; LiveView drops `seq <= last_seq` duplicates. ✅ | met |
| 4 | — | acceptance | — | Settled runs show buffer until `terminal_linger` expires (same lifecycle as `Run.status/1`). ✅ | met |
| 5 | — | acceptance | — | `Run.transcript/1` returns `{:ok, %{buffer, seq}}` or `{:error, :not_found}`. ✅ | met |
| 6 | — | acceptance | — | Broadcast tuple carries `seq`; LiveView dedups on `seq <= last_seq`. ✅ | met |
| 7 | — | acceptance | — | `Harness.Dashboard.Transcript.append/3` is the shared trim helper. ✅ | met |

## Auto-applied fixes

- `lib/harness/dashboard/live.ex` — new `handle_info({:harness_transcript, broadcast_run_id, _seq, _chunk}, socket) when broadcast_run_id != socket.assigns.run_id` guard clause; comment explains the cross-run mailbox-bleed scenario.
- `lib/harness/agent_adapter/driver.ex` — `:on_output` docstring updated to describe the generic 1-arity contract + name the current `Harness.Run` consumer shape and downstream `Transcript.broadcast/3` (was `/2`).

## Discuss-tier resolutions

— None.

## Codex second-opinion

Status: dual-reviewer (jobId task-mpnowqxu-hc2kfi).
Corroborated findings: —
Codex-only findings (verified + applied): 1, 2.

Codex reproduced the cross-run bleed locally with Phoenix.PubSub + `Harness.Dashboard.Live.handle_info/2` and cited both `Phoenix.PubSub` and `Phoenix.LiveView` hex docs; its `mix dialyzer.json`, `mix credo`, and `mix reach.otp` were sandbox-blocked on TCP `:eperm` but `mix test.json --quiet --failed` ran cleanly.
