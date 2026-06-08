# Decision: keep the per-agent transcript + token-usage parsers

**Date settled:** 2026-06-09
**Status:** Decided — **KEEP both**. Rationale recorded so it is not re-litigated.
**Task:** rmap 222 ("DECIDE: collapse the 6 transcript parsers + 6 token-usage parsers toward raw/generic").
**Scope:** `lib/harness/dashboard/transcript/parser.ex` + `parser/*` (7 files, ~720 LOC) and
`lib/harness/token_usage.ex` (6 per-adapter parsers, ~285 LOC).

## The question

These parsers couple harness to each agent's wire format. The raw-passthrough thesis
(`CLAUDE.md` § "Not a wrapper around one agent" + § "No agent-output parsing") was written to
keep exactly that coupling out of harness — "agents ship 40+ releases; a JSON-format change is
absorbed by the AI reading the transcript, not by breaking a normalization layer." So the
contested framing was: are these parsers the brittleness the thesis forbids, and should they
collapse to a generic/raw view?

## The decision: keep both

The collapse argument rests on a premise that does not hold for *these* parsers: that a
format change **breaks** something. It does not — both families are failure-tolerant by
construction, and neither sits in the load-bearing success path.

### 1. They are not in the verdict path — the thesis does not reach them

The raw-passthrough thesis is specifically about **success determination**: harness decides
"did the job succeed?" from the reviewer AI's `.harness/review.json` artifact, *never* from
parsing the implementer's output. That path has zero parsing and is untouched here.

- **Transcript parsers** feed only cold-path **display** — the run-detail `<.transcript_view>`
  (`live.ex:568`) and the A/B compare view (`compare_live.ex:517`). Nothing routes, gates, or
  merges on their output.
- **Token parsers** produce **facts**, not judgment — `input`/`output`/`total` counts that feed
  the KPI ledger (`agent_kpi.ex:369`), the run record at settle (`run.ex`), and a dashboard
  cell. THE MANTRA explicitly lists "summed tokens" as a fact harness *may* count. Counting a
  token is mechanics; it is not deciding what a run means.

### 2. They already degrade gracefully — the feared failure mode never materializes

The brittleness the thesis guards against is "a JSON-format change breaks a normalization
layer." These layers cannot break:

- `TokenUsage.parse/2` — "a format that carries no usage at all parses to `empty/0` (all-`nil`)
  — never a crash." A format change silently yields missing token facts; the KPI cell renders
  `—`. No crash, no false verdict.
- `Transcript.Parser` — "unknown / malformed lines are preserved (`{:unknown, %{raw: line}}`) —
  never silently dropped, never crash." A format change degrades the chat-view **to raw
  passthrough automatically**, per line. The generic/raw fallback the collapse would impose
  already exists as the failure mode.

So collapsing buys **zero** robustness: the pipeline already cannot break on format churn, and
the worst case already *is* the raw view.

### 3. Collapsing has a real cost — the structured display

A generic/raw view loses the structured chat-turn rendering (assistant text / tool-use /
tool-result grouped into turns) that is the entire product value of the transcript view, and
loses the per-agent token-efficiency signal the dashboard and a future history-based router
consume. That is a concrete regression traded for no gain.

### 4. The marginal cost per adapter is small and bounded

The maintenance worry (12 parsers across 6 churning agents) is real but contained:

- Transcript parsers share `use Harness.Dashboard.Transcript.Parser` + `Harness.LineParser`;
  each is a ~50–120 LOC `translate/1` clause table, and the dispatcher is one clause per adapter.
- Token parsers share `json_objects/1`, `sum_usages/2`, `count/1`, `add_field/2`, `put_total/1`;
  each `parse_*` / `from_*_usage` is ~10 LOC.

Adding or fixing an adapter is a localized edit, and a stale parser fails soft (empty facts /
raw lines), so an unnoticed format drift degrades display rather than corrupting state.

## Consequence

- **No follow-up implementation task.** Nothing collapses or is deleted.
- **Do not re-litigate** by citing "No agent-output parsing" against these modules: that rule
  governs the success/verdict path, which is artifact-driven and parser-free. Cold-path display
  and fact-counting that degrade to empty/raw are outside its scope and are kept deliberately.
- If a future agent's wire format *does* churn, the fix is a localized `translate/1` /
  `from_*_usage` clause — not a rewrite, and never an emergency, because the failure is soft.
