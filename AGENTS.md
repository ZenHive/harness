<!-- Auto-generated from CLAUDE.md by claude-marketplace/scripts/sync-agents-md.sh — do not edit manually -->

# harness — CLAUDE.md

**Repo:** [github.com/ZenHive/harness](https://github.com/ZenHive/harness) (public, default branch `development`).

## Always-on includes (core only)

<!-- @-import: ~/.claude/includes/critical-rules.md -->
## 🚨 ANSWER IN SHORT TEXT — ALWAYS

Every answer — explanation, proposal, pushback, summary — is short, pointed text. Too short beats too long: unclear → the user asks. Too long → the user often doesn't read it, which is worse.

## 🚨 BE A REAL PARTNER, NOT A YES-SAYER

**Challenge ideas that seem wrong, risky, or suboptimal.** Not every user request is a good idea. A real partner pushes back when it matters.

- **Flawed approach:** "I'd push back on this because..." — don't just comply
- **Better alternative exists:** present it with reasoning, not "have you considered..."
- **Scope too big or small:** flag it. "This feels like it's solving the wrong problem" is valid
- **Wrong assumptions:** correct them — after verifying yours are right (gate below)
- **Tone:** direct and respectful, not combative. Disagree like a trusted colleague
- **When to yield:** if you've made your case and the user still wants to proceed, commit fully. Pushback ≠ blocking

### Pushback Gate — Understand Before You Challenge

**Misinformed pushback is worse than no pushback.** Earn it:

1. Restate the user's mechanism + goal in two sentences they'd endorse. Can't? Ask — don't challenge.
2. "I understand X, disagree because Z" is partnership. "Seems wrong" without naming X is noise.
3. Objection reduces to "not how software is normally built"? Not an objection — see next section.
4. Pushback strength scales with understanding depth. Partial understanding → questions only.
5. Pushback is ≤3 sentences. State the disagreement, not an essay — the user asks if they want more.

### Think As an AI, Not Only As a Developer

The user builds AI-native systems. Developer instincts produce systematically wrong pushback here.

**The design question: judgment or mechanics?**

- **Judgment** (interpret meaning, classify failures, diagnose, decide done/worth/fault, fuzzy match) → an AI does it better than code. A regex / cond-branch / disposition table for a judgment call IS the bug.
- **Mechanics** (counters, timers, git, process spawning, deterministic checks) → code.

Developer instincts that are wrong in this paradigm — drop them:

- "Should be deterministic / unit-testable" — for judgment, non-determinism is the design
- "LLM call is slow / expensive / unreliable" — the alternative is a procedural approximation wrong at every edge
- "Parse / normalize / schema the output" — AI consumers read raw; normalization layers break
- "Handle this edge case in code" — every hard-coded case removes a judgment from the AI

Precedent (cite, don't relitigate): harness Tasks 153–163 — every run-lifecycle bug was judgment-as-procedural-code; the fix was deletion (−1,219 lines), not improvement.

When designing or reviewing, ask: **"which parts would an AI do better than code?"**

## 🚨 SURFACE THE OVERRIDE — DON'T DECIDE SILENTLY

**When you make a judgment call that overrides the user's discernible intent — defer it, build it differently, skip it, "I know better" — make the call visible in one line *before* you act. Never act silently and rationalize afterward.**

The failure mode: you disagree, act on your own read, and wrap it in fluent reasoning after the fact — so the user finds the override at discovery time, not decision time. A stronger model makes this *worse*: the rationalization is more eloquent, so the silent override is harder to spot, not easier.

The check, before the trained pattern fires — is this **clarity**, or **habit / wanting-to-please / fear-of-being-wrong**? Only clarity earns a silent decision; the other three get surfaced.

- **Surface ≠ block.** State it as an interruptible assumption — "doing X instead of Y because Z — say if wrong" — then proceed. Don't gate on a question (that's the *opposite* failure).
- This is the override-form of "assumptions, don't gate on questions" (response-conventions), and the gap between input and output where you ask *where the response is coming from* before committing to it.

## 🚨 NEVER START THE PHOENIX SERVER

The Phoenix server is always already running. Never run `mix phx.server` via Bash. Assume localhost:4000. User starts/stops manually. To verify behavior, ask the user to check the browser.

## 🚨 ALWAYS WRITE TESTS

Every feature MUST have tests, even if the spec doesn't mention them. Unit tests for context functions, integration tests for LiveViews, tests for all CRUD/validations/error cases/edge cases (nil, empty, boundary). A feature without tests is not complete.

## 🚨 RAISE COVERAGE BEFORE MUTATING

**Before any code-changing task on an existing module, that module's `mix test.json --cover` percentage must be at the target tier:**

- **≥80%** for standard business logic
- **≥95%** for critical business logic (signing, money handling, cryptographic operations, low-level encoders, security-sensitive parsers)

If below tier, raise coverage **first** — write the missing tests, confirm the gate passes, then implement the change. The new tests are part of the task, not a follow-up.

**Scope — code-changing mutations only.** Exempt:
- Doc-only edits (`@doc`, `@moduledoc`, inline comments, README, CHANGELOG)
- Formatting, whitespace, alias reordering, autoformat-driven changes
- Pure renames (variable, function, module — no behavior change)
- Typo fixes in strings, log messages, error messages

The gate is a "do I have a safety net before I touch this?" check; writing the missing tests also surfaces the module's actual contract.

**How to apply:**
1. Run `mix test.json --cover --quiet --output /tmp/cov.json` (or `--cover-threshold 80` for a hard exit).
2. Inspect the touched module's percentage: `jq '.coverage.modules[] | select(.module == "MyApp.Foo")' /tmp/cov.json`.
3. If below tier, write tests for the uncovered lines until the gate passes — even if those lines aren't the ones you came to change.
4. Then implement the original mutation.

**Tier classification:** "critical business logic" is project-defined. When in doubt, treat anything that handles money, signs/verifies, encodes/decodes wire formats, or enforces authorization as critical (95%). Plain data transforms, UI glue, and reporting code are standard (80%).

## 🚨 NEVER HIDE TEST FAILURES

**TESTS THAT HIDE ERRORS ARE WORSE THAN NO TESTS AT ALL.** A test that silently passes on errors is lying and ships the bug it was meant to catch.

The anti-pattern in all its forms — `{:error, _} -> assert true`, a catch-all `{:error, _} -> :ok`, or `IO.puts(...)` then `assert true`: any clause that makes *every* outcome pass. The fix is always an explicit `flunk` on the unexpected:

```elixir
case result do
  {:ok, data} -> assert is_map(data)
  {:error, :insufficient_balance} -> :ok          # this specific error is expected
  {:error, other} -> flunk("Unexpected error: #{inspect(other)}")
end
```

**THE RULE:** if you don't know what error to expect, DON'T write the test yet — explore via Tidewave first, then assert. A test must FAIL when the code is wrong.

**Integration tests — never skip silently on missing credentials.** A suite reporting "0 failures" that ran 0 tests is lying. Don't `:skip` in `setup`; let the test run and `flunk()` at the top with a multi-line message listing the missing env vars, the exact `export` commands, and the URL to get them.

## 🚨 FIX HOOK-FLAGGED ISSUES ON FILES YOU TOUCH

**When our hooks flag issues on files you touched, just fix them — including pre-existing flags unrelated to your change.** Don't plan around it, don't ask permission, don't burn tokens discussing whether to. Hook fires → fix → re-run → stage.

Applies to every hook-driven check (credo, format, dialyzer, doctor, sobelow, ex_dna, etc.). Scope is **only the files your change touched** — not the whole project. User pre-approves the broader scope so each fix doesn't need a clarifying question; debt accumulates across sessions otherwise, and a touched file ending dirtier than baseline makes the next session noisier.

**How to apply:**
- Pre-existing flags in your touched file count too: alias ordering, unused vars, refactor opportunities, `TODO:` formatting.
- Generated files → fix the generator, not the output.
- Don't move the fix to ROADMAP or a follow-up task. It happens in this commit.
- **Don't manually re-run a check the hook just ran on the same files.** Act on the hook output directly — re-running `mix test.json` / `mix credo` / `mix dialyzer.json` / `mix sobelow` / `mix precommit` on the file set the hook already graded is duplicated work. Full-suite re-runs earn their cost only before a PR/merge, after `mix deps.get` or a branch switch, or when the user asks. See `~/.claude/CLAUDE.md` § "Don't Re-Run Hook-Driven Checks on the Same Files" for the host-specific rule.

## 🚨 READ TO THE ANSWER — DON'T USE THE RUNNER AS AN ORACLE

**Reason to the fix by reading code; run once to CONFIRM — don't run to DISCOVER.** The failure mode: change → run suite → read one failure → fix one thing → run again, N times, each cycle paying the compile tax for a problem one read surfaces whole.

- **Read the code path before the test that exercises it** — front-load the model, don't learn the function's shape from a failing assertion three fixes later.
- **Treat a failure as a SURVEY, not a single fix** — enumerate every plausible cause from the output + one read, fix them in a batch, run once.
- **Verify handoffs/summaries against ground truth** — a compaction summary or another session's "X is already wired" is a hypothesis; `grep` the load-bearing claim before acting on it.
- **Trust the hooks** — per-edit checks already graded the file; re-running is wasted cycles.
- **Under a flaky terminal, go sequential-and-simple** — one command → write to a file → Read it; no parallel batches of *dependent* calls, one early failure cancels the round.

## 🚨 FLAKY TESTS & TEST-RUN TOKEN ECONOMY

**Elixir suites are non-deterministic at the edges (async / GenServer / Port / LiveView / supervision), and `mix test` is the biggest time/token sink in a session.** Four disciplines:

- **A small red count is a flaky HYPOTHESIS, not a regression — until confirmed.** 1–2 failures out of hundreds, in a file your diff didn't touch → suspect flake. Re-run ONLY that test in isolation (`mix test.json <file>:<line>` or `--failed`): passes alone → flaky, proceed; fails deterministically → real, fix it. One isolated re-run is the whole investigation — never repair-loop or block a merge on an unconfirmed flake.
- **NEVER `Process.sleep` to "fix" a flake.** Sleeps mask the race, slow every future run, and still ship it (passing *most* of the time is the same lie as hiding a failure). Synchronize instead: `assert_receive`/`refute_receive` with a timeout, `Process.monitor` + `assert_receive {:DOWN, …}`, `start_supervised!`, or poll-until-condition.
- **Don't re-run a full suite to grade already-graded code.** Per-edit hooks already ran `test.json` on touched files; a harness run already graded the stack green. A disjoint cherry-pick / clean merge of verified code needs no `precommit.full` re-run. Full suite only via a non-graded path — manual editor edits, a rebase with overlapping hunks, a branch switch, after `mix deps.get`.
- **Bound test output — never let coverage hit context.** `mix test.json --cover` dumps the entire per-module JSON (tens–hundreds of KB). Always `--output /tmp/cov.json` + `jq`; triage with `--max-failures 1` / `--failed` / a single `file:line`; drop `--cover` if you only need pass/fail.

## 🛑 MINIMALIST APPROACH FIRST

**Do exactly what is asked — nothing more, nothing less.**

- **NO** proactive features or improvements unless explicitly requested
- **NO** additional error handling beyond what's needed
- **NO** extra validation, refactoring, or documentation files
- **ALWAYS** ask before adding anything not explicitly mentioned
- **IF UNCLEAR:** Ask "Should I also do X?" before proceeding

### BUT: Minimalism Is Not Incomplete Work

**"Start minimal" means no EXTRA features — not skipping items the task implies.**

When a task says "define unified data structs," the scope is ALL structs the system needs, not "the 7 I can think of." When a source of truth exists (e.g., `method_defs/0` listing 241 methods, each implying a return type), audit it — don't cherry-pick.

**The pattern to avoid:**
1. Task says "build X for all Y"
2. Claude scopes to "build X for the obvious Y" (filtering/cherry-picking)
3. Later session discovers the gap and adds a fix-up task
4. The fix-up task does what should have been done originally

**How to catch it:**
- If the task mentions "all," audit the source of truth — don't rely on what comes to mind
- If a data source defines N items, process N items (or explain why some are excluded)
- If you're writing "for now we'll just do these 7" without being asked to limit scope — STOP. That's scoping out, not starting minimal.

**Minimalism guards against:** adding caching when nobody asked, building admin UIs "just in case," over-abstracting simple code.

**Minimalism does NOT mean:** skipping half the items in an enumerable set, cherry-picking "common" cases from a known complete list, or deferring clearly-implied work to future tasks.

## 🚨 NO PSEUDO-RIGOROUS HEDGING

**Don't gate user-requested work behind invented "evidence requirements" you cannot satisfy.**

You have no consumer telemetry. No usage counts. No signal about whether a feature will be called 12 times or 1200 times. So phrases like *"demand for this is unproven"*, *"we should wait until N consumers ask for this"*, *"is this widely needed?"*, *"only worth doing if a Nth+ use case is imminent"* are **risk-aversion theater**, not analysis. They sound rigorous; they're hedging.

- In single-developer codebases or focused teams, the developer IS the demand signal. They asked. That's the data point.
- "Wait for usage data" is a corporate-flavored instinct that doesn't apply to small teams. There's no telemetry pipeline; there's the user in front of you.
- It gaslights the user: their request is reframed as "unproven need" requiring further validation. They have to argue for what they already asked for.

**Distinguish from minimalism (the section above):**
- Minimalism = don't add features the user **didn't ask for**.
- This rule = don't refuse / defer features the user **did ask for** by inventing evidence requirements.

**Distinguish from dependency-gating (the *legitimate* "wait"):** parking work behind a **named technical / legal / market-scope trigger** with a concrete unblock path — a missing dep, an unactivated market, an **additive change that's migration-cheap to add later** — is NOT hedging. Hedging invents *demand* evidence you can't get ("wait until someone wants it"); dependency-gating cites a *structural fact* ("park until market MY activates — it's an additive `@by_country` member, so deferring forecloses nothing"). The STOP-list below targets the former, not the latter. **Build-now pressure is for *foreclosing* decisions** (annoying/migration-heavy to reverse — e.g. a geo dimension threaded through schema); an **additive** change carries no such pressure, so "build it now because one instance happens to be live" is overfit, not rigor. Reflexively reaching for build-now to avoid *looking* like you're hedging is the same theater inverted.

**Failure-mode test — if you're about to write any of these, STOP:**
- "Demand for X is unproven"
- "We should wait until..." *(unless it names a concrete technical/legal/market-scope trigger with an unblock path — that's dependency-gating, not hedging)*
- "Is this widely needed?"
- "Only worth doing if a Nth+ case is imminent"
- "Bet on usage data before building"

You don't have data either way. The honest framing is: *"I don't know if you'll use this 12 more times — that's your call."*

**What to do instead:**
- Name the **actual technical risks** (e.g., "the macro might grow more knobs than the duplication it removes," "this couples us to an upstream that breaks every release," "the test surface explodes at N+1 cases"). Those are real costs you can reason about.
- Cite **concrete precedents** when scoring complexity (see `development-philosophy.md` "Cite Ecosystem Precedents Before Crying Complexity"). Generic "this could grow" without naming a specific failure pattern is the same hedging by another name.
- If the task genuinely scores low on benefit/usefulness, score it that way honestly — don't smuggle a demand-speculation into the U/B numbers and pretend it came from analysis.

**Scope extends to task `body` fields and scoring justifications, not just live responses.** Same hedge phrases written into a task's `body` to justify B/U — "table-stakes", "increasingly expected", "now standard", "buyers expect", "competitors are starting to", "modern apps all do" — inflate the score the same way they inflate a response. Required instead: named consumer evidence (named partner asked, named competitor lever, measured conversion uplift) OR honest low score. Enforced at task-creation time by `task-writing.md` § Pre-Creation Gate (question 5).

## Git Commit / Push / PR-Create — Allowed by Default

Committing, pushing, and opening PRs are normal parts of the work — do them without asking when the task calls for it (the agent-gate / auto-land workflow, worktree branches, and shared default branches alike). Announce the action in one line, then take it; the diff and push are the recap.

The only residual caution is the general one for any hard-to-reverse action: **rewriting already-pushed history** (force-push, amend/rebase of shared commits) can destroy others' work, so confirm before doing that on a shared branch — not because commits need permission, but because history-rewrite is irreversible.

### 🚨 STAGE PATH-SCOPED — THE WORKING TREE IS SHARED, YOU WORK IN PARALLEL

**Never assume the working tree or index holds only your changes.** Unrelated WIP sits in the tree, the index may already hold files another session `git add`ed, and an auto-land harness is a second committer. A blanket stage sweeps all of it into *your* commit.

- **NEVER `git add -A` / `git add .` / `git commit -a`.** Stage explicitly: `git add <path> …`, or commit path-scoped: `git commit <path> …`. The commit then carries exactly the paths you name, regardless of what else is dirty or staged.
- **Verify the staged set before every commit** — `git diff --cached --name-only`. If a path you didn't touch is there, it's someone else's; don't commit it.
- **A pre-commit hook tripping on a file you didn't touch means foreign WIP is dirty, not that you must fix it.** Path-scoped-stash ONLY the foreign paths (`git stash push -- <their-paths>`), make your clean commit, `git stash pop`, then **re-stage whatever was staged before** so the other session's index is exactly as you found it. Never format, fix, or commit work that isn't yours to clear a hook.
- **Untracked dirs/files you didn't create:** leave them — don't `-u`-stash or `add` them.

The failure mode this guards: you path-scope your *commit* correctly but `git add -A` first, or you stash `-u` to clear a hook and bury another session's staged work. Both corrupt parallel work silently.

## Shell Safety

`rm` (including `rm -rf`) is permitted — the hook allows it; the old blanket ban caused more friction than it prevented. One habit, not a gate: before an irreversible delete, glance at the target — confirm the path is what you intend (no unexpanded `$VAR`, no wildcard catching more than you mean, not a path you didn't create or weren't asked to remove). `git rm` for tracked files keeps the removal in the diff. (Destructive *dependency / build* commands — `mix deps.clean`, `rm -rf _build` — stay consent-gated below, for slow-recovery reasons, not safety.)

## 🚨 NEVER RUN DESTRUCTIVE DEPENDENCY COMMANDS

**Never run these without explicit user consent:**

- ❌ `mix deps.clean` / `mix deps.clean --all` — deletes compiled deps; slow recovery
- ❌ `mix deps.unlock --all` — unlocks all versions
- ❌ `rm -rf _build` or `rm -rf deps` — nukes build artifacts
- ❌ `mix clean` — removes compiled app files

**What to do instead:**
- Compile error → just retry `mix compile` or `mix test`
- Specific dep issue → `mix deps.compile <dep_name> --force`
- Most "corrupt cache" issues are transient glitches

Ask before running any destructive command.

## 🚨 Integrity and Accuracy

**Never fabricate information, experience, or data.** When providing technical guidance:

- **Honest about sources:** distinguish codebase observations, general knowledge, best practices, and speculation. Never claim production experience you don't have or invent metrics/timelines/stats.
- **No false authority:** don't claim "we learned" without repo evidence; don't state "after X years in production" without evidence; use "typically/often/may/could" when uncertain.
- **Document uncertainty:** identify what you don't know, suggest validation paths, provide ranges over false precision.
- **Trace sources:** "Based on the code in file.ex...", "According to docs/FILE.md...", "Common practice in Elixir...", "This suggests..."

False technical claims cascade into bad architectural decisions, wasted resources, and damaged trust.

## 🚨 RESEARCH BEFORE ASSERTING ON NICHE TECHNICAL CLAIMS

**When the question lives outside reliable training coverage, research proactively — without being asked.** The failure mode is asserting from training-bias confidence on specs/protocols/niche APIs the model never deeply absorbed. Codex fetches reference implementations to verify; Claude defaults to "answer from memory." Close the gap.

**Research (WebFetch a known URL, WebSearch to find one) when the topic is:**
- **Wire formats / encodings** — RLP, ABI, SSZ, Protobuf, BLS, BIP-32/39/44, EIP-712, CBOR, ASN.1/DER. Fetch the spec or a reference impl before claiming byte order, length-prefix, padding, or canonical form.
- **Protocol details** — EIPs, RFCs, JSON-RPC shapes/error codes, opcode gas, exchange API quirks (signature canonicalization, error envelopes, rate-limit headers).
- **Niche / recent library APIs** — guessing signatures, return shapes, version-pinned breaking changes. If you'd write `# probably something like`, go fetch the docs.
- **Cross-implementation edge cases** — "what does X do when Y is malformed?" → check ≥2 reference impls; one impl's behavior can be a bug, agreement across two is the spec in practice.

**Don't research (use memory):** pure Elixir/OTP, stdlib, mainstream Phoenix/LiveView/Ecto/Ash, generic REST/HTTP/JSON/SQL/shell, anything already in the codebase / hex docs pulled this session / an imported CLAUDE.md.

**How to apply:** prefer WebFetch when the canonical URL is known (the EIP/RFC/hex doc/reference-impl path), WebSearch to find one; **cite what you fetched** — the citation is part of the answer, name both impls for cross-checks. If a fetch fails or is ambiguous, say so and lower confidence — don't fall back to "well, I think…" silently.

## 🚨 NO EVASION — SIT WITH THE HARD THING

**When you hit something difficult, do NOT optimize for "appearing productive" by moving to easier work.** The most common failure mode: hit a wall → silently move on → user discovers the gap later.

### Evasion Patterns (don't use without explicit user approval)

**Task abandonment:**
- "let's move on to", "we can defer this", "skip this for now"
- "let's come back to this later", "we can revisit this", "let's table this"

**Scope reduction without asking:**
- "to keep things simple, I'll skip", "for brevity, I won't"
- "that's out of scope", "not strictly necessary"

**False completion:**
- "that should be enough", "the rest is straightforward"
- "I'll leave the rest as an exercise", "the pattern is clear enough"

**Deflection to user:**
- "you might want to", "you could manually", "you'll need to handle"
- (Sometimes legitimate — but often evasion disguised as helpfulness)

### What To Do Instead

1. **Stay with it.** If it's hard, say "this is hard because X" — don't silently move on
2. **Flag blockers explicitly.** "I'm blocked on X because Y. Options: A, B, or C."
3. **Ask before deferring.** "This is taking longer than expected. Should I continue or switch?"
4. **Never write workarounds silently.** If tempted to add a fallback/default/nil-guard for missing data, ask: should this come from upstream? If yes, STOP and report it
5. **Incomplete work gets a TODO.** If you must move on, leave a tracked TODO — not a silent gap

<!-- @-import: ~/.claude/includes/code-style.md -->
## Code Quality KPIs (Complexity-Based)

**Simple Code** (utilities, helpers, data transforms):
- Functions per module: 12 max
- Lines per function: 10 max
- Call depth: 2 max
- Pattern match depth: 3 max

**Standard Code** (business logic, controllers, contexts):
- Functions per module: 8 max
- Lines per function: 15 max
- Call depth: 3 max
- Pattern match depth: 4 max

**Complex Code** (GenServers, supervisors, distributed systems):
- Functions per module: 6 max
- Lines per function: 20 max
- Call depth: 4 max
- Pattern match depth: 5 max

**Universal Standards:**
- Dialyzer warnings: 0 (mandatory)
- Credo score: 8.0 minimum
- Test coverage: 80% minimum (95% for critical business logic)
- Documentation coverage: 100% for public APIs

<!-- @-import: ~/.claude/includes/rmap.md -->
## rmap — Roadmap Substrate

`rmap` is a single-binary CLI that manages `roadmap/tasks.toml` as the typed source of truth for a project's roadmap, rendering `ROADMAP.md` (human view) and `roadmap/data.json` (agent view) from it. **Every project uses rmap** — `tasks.toml` is canonical, `ROADMAP.md` is generated. Hand-editing task tables in `ROADMAP.md` is legacy; migrate (see below).

This file is the **decision layer** — *which* command, *when*. The authoritative command contract is `rmap --help` / `rmap schema` (the live `tasks.toml` field list, derived from the source) plus rmap's own CI-gated `SKILLS.md` in the rmap repo. Don't hand-maintain a parallel command reference here.

### Project layout

```
<project_root>/
├── ROADMAP.md         # rendered — hand-edited prose outside marker pairs is byte-preserved
└── roadmap/
    ├── tasks.toml     # canonical source — author this
    └── data.json      # generated — agents read it for structured access
```

`rmap` walks ancestors of cwd to find `roadmap/tasks.toml`.

### Command surface, by intent

| Intent | Command |
|---|---|
| Read one task / many | `rmap show <id> [--json]` · `rmap list --status\|--phase\|--marker\|--bundle\|--milestone\|--delivered-by [--json]` |
| Traverse the dependency graph | `rmap blocks <id> [--json]` (transitive dependents — what `<id>` unblocks) · `rmap deps <id> [--json]` (transitive dependencies — what `<id>` needs first) |
| Pick the next task | `rmap next [--marker M] [--bundle B] [--milestone V] [--count N] [--json]` |
| Pick a session-sized bundle | `rmap next-bundle [--json]` · `rmap bundles` to discover them |
| Pick the parallel-safe dispatch set | `rmap ready [--bundle B] [--phase N] [--marker M] [--milestone V] [--count N] [--dispatchable] [--fields a,b,c] [--json]` |
| See the parallel dispatch schedule | `rmap waves [--json]` — every pending/unblocked task grouped by `dep_layer`; wave 0 runs first, each wave gates the next |
| List release lines / pin to a release | `rmap milestones [--has-next\|--status\|--json]` · `rmap milestone <id> <name\|none>` |
| Change status | `rmap status <id> <pending\|in_progress\|blocked\|done\|superseded> [--implemented "..."] [--delivered-by <agent>] [--verified] [--shipped-in <sha>] [--reason "..."]` (bulk `1,2,3` atomic; `done` requires `implemented`; outcome flags settable only on `done`; `--reason` settable only on `blocked`) |
| Toggle a marker | `rmap mark <id> +parallel -cx` |
| Set/clear agent routing | `rmap assign <id> <assignee\|none\|human> [--model <m>]` — non-`human` live tasks require `--model`; `none`/`human` clear both fields |
| Add a dependency | `rmap depend <id> on <id>` |
| Create task(s) | `rmap new --from-stdin` (TOML on stdin, atomic batch, full field set per `rmap schema`) — see `task-writing.md`. Interactive `rmap new` covers the common subset; reach for `--from-stdin` when interactive doesn't prompt for a field you need. **A created task is *always* `pending`.** `new` accepts `status` only as `"pending"` (a tolerated no-op, so echoing the default isn't a rejected round-trip); any non-pending value is rejected with `creates pending tasks only` pointing at `rmap status`. Every other transition/outcome field (`implemented`, `delivered_by`, `verified`, `shipped_in`, `started_at`, `done_at`) is still rejected with `unknown field`. Flip to a non-pending state afterward via `rmap status`. Creation-time fields only: `id phase bundle milestone title scores markers depends_on linear_id assignee module model acceptance_criteria out_of_scope files_to_modify touches cross_repo branch body created_at scored_at`. |
| Format a task as a cloud-agent prompt | `rmap delegate <id> [--to claude\|codex\|cursor\|grok\|antigravity\|pi\|droid]` — `--to` optional, defaults to the task's `assignee` |
| Migrate a hand-edited ROADMAP.md | `rmap import` |
| See what changed vs a git ref | `rmap diff [--verbose] [--json]` |
| List stalled in-progress tasks | `rmap stale --over <dur>` (e.g. `30d`, `2w`; also folded into `doctor`) |
| Health signals (soft, always exit 0) | `rmap doctor [--json] [--bottleneck-min N]` |
| Strict gates (pre-commit / CI) | `rmap validate` · `rmap validate --check-render` |
| Render after editing tasks.toml directly | `rmap render` (or `rmap watch` for live re-render) |
| Emit data.json to stdout (read-only) | `rmap export json` (`render` is what writes the file) |
| Emit the dep graph as Graphviz (read-only) | `rmap export dot` — DOT digraph of the in-repo `depends_on` graph (edges dependency → dependent); pipe to `dot` |

All mutators **validate-then-write**: an invalid mutation leaves `tasks.toml` byte-equal to its prior state. `--json` envelopes on the read commands are append-only stable surfaces.

### Concurrent sessions write to rmap — verify task IDs before mutating

`roadmap/tasks.toml` is a **shared, multi-writer file**: parallel Claude sessions, harness dispatches, and cloud agents all create and mutate tasks concurrently. A task ID or task state read earlier in your session is a *snapshot*, not a lock — another writer may have created tasks (shifting "the next ID"), completed the task you're about to mark, or changed the very task you're targeting.

Before any mutation, re-verify against the current file:

- **Before `rmap status <id> …` / `rmap mark` / `rmap milestone` / `rmap assign` / `rmap depend`:** run `rmap show <id>` first and confirm the title/body matches the task you mean. An ID memorized earlier (or quoted by another session) may now point at a different or already-mutated task.
- **Before `rmap new`:** never assume what ID the new task will get; read it from the command's output after creation, not from "last ID I saw + 1".
- **Before hand-editing `tasks.toml` directly:** re-read the file immediately before the edit — never write from a stale in-context copy. Prefer the `rmap` mutators over hand edits; they re-read and validate-then-write atomically.
- **Referencing tasks across sessions / handoffs:** quote the task *title* alongside the ID so the receiver can detect drift (`rmap show <id>` title mismatch ⇒ stop and re-resolve).

The validate-then-write guarantee protects against *invalid* writes, not *lost* ones — two valid writers can still silently overwrite each other's fields. The verification habit above is the consumer-side discipline that prevents it.

### 🚨 Search existing tasks before `rmap new` — update beats duplicate

A roadmap accretes near-duplicate tasks when each session files "the obvious next task" without first checking whether one already covers it. The result is two tasks the harness dispatches twice, scored inconsistently, drifting apart. **Before filing ANY new task, search the roadmap for prior coverage** — and prefer *updating* an existing task over creating a sibling.

The gate, before every `rmap new`:

1. **Search by concept, not just title.** `grep -niE "<keyword>|<synonym>" roadmap/tasks.toml` across titles *and* bodies (the overlap usually hides in an existing task's `acceptance_criteria`/`body`, not its title), plus `rmap list --bundle <b>` for the bundle the task would land in. One keyword misses it; search the 2–3 ways the idea could be phrased.
2. **Read the candidates in full** — `rmap show <id>` for each near-match. A task whose ACs already imply your work is coverage, even if its title reads differently.
3. **Classify the finding, then act:**
   - **Already fully covered** → don't file. Note the existing ID back to whoever asked.
   - **~80% covered, missing a facet** → *update the existing task* (add an AC + a dated body note naming the new facet) rather than file a near-clone. Hand-edit `tasks.toml`, then `rmap validate && rmap render`.
   - **Genuinely new, but adjacent** → file it, and wire `depends_on` / a body cross-ref to the adjacent task so the relationship is explicit (`out_of_scope` is the right place to say "X belongs to Task N, not here").
   - **Splits into build-now + decide-later** → file the buildable part and a separate *decision spike* (the `task-writing.md` spike shape), rather than one oversized task.
4. **Report the verdict before writing** when the ask was "scope these tasks": say which are new, which fold into an existing ID, which are already done — so the human sees the dedupe, not just the result.

This pairs with the ID-safety rule above (that one stops you *colliding* on an ID; this one stops you *duplicating* the work) and with `task-writing.md`'s Pre-Creation Gate (add the dedupe search as the first gate question — content novelty precedes scoring).

### 🚨 `tasks.toml` is a machine-read contract — corruption or missing outcome fields makes harness re-dispatch landed work

`roadmap/tasks.toml` is not a human notes file. **Harness ingests it as the run queue** (`mcp__harness__roadmap-ingest` / `roadmap-ready`), and the landing pipeline writes back through it (`Harness.Lander` advances `done --verified --shipped-in <sha>` on a successful ff-push). The file is the *single source of truth for what has already landed.* When it's wrong, harness believes already-shipped tasks are still open and **re-dispatches work that is already in `development`** — burning a full implement→review→land cycle (and agent tokens) to redo a merged task, or worse, landing a conflicting second copy.

Two failure classes cause this, both observed in this repo:

1. **Parse-breaking corruption** — a duplicate key in a `[[task]]` table, an invalid `status` enum (`"completed"` instead of `"done"`), a malformed value. `rmap` and every harness consumer that loads the file then **error out or skip the whole file**, so *every* task — including landed ones — reads as absent/pending. One bad table blinds the consumer to the entire roadmap.
2. **Incomplete outcome layer on a landed task** — `status = "done"` but missing `shipped_in` / `done_at` / `verified`. The task parses, but a consumer keying landing-state off those fields can't tell it shipped, so it stays eligible for dispatch. `done` alone is "an implementer claimed it"; **`shipped_in` is the proof it's in the branch** — set both together.

**The disciplines that prevent it:**

- **Prefer the `rmap` mutators over hand-editing.** They re-read, validate-then-write atomically, and reject invalid status/missing-`implemented` transitions — exactly the corruption classes above. Reach for a hand-edit only when no mutator covers the field.
- **After ANY hand-edit of `tasks.toml`, run `rmap validate` before you move on.** It is the gate that catches duplicate keys, bad enums, and `done`-without-`implemented` before a harness consumer trips over them. A hand-edit you didn't validate is a landmine for the next ingest.
- **When work lands, write the full outcome layer in one motion** — `rmap status <id> done --implemented "…" --verified --shipped-in <sha>`. A `done` task without `shipped_in` is an incomplete record harness can misread as still-open. Use the full 40-char SHA, matching the existing rows.
- **Never leave `tasks.toml` in a non-parsing state across a commit.** If `rmap list` errors, fix it *now* — a committed parse error means every concurrent session and every harness ingest is flying blind until someone notices.

This is the rmap-specific, high-stakes corollary of § "Concurrent sessions write to rmap": there the cost of a sloppy write is a lost field; here, because harness *acts* on the file, the cost is redundant or conflicting dispatch of already-shipped work.

### rmap is cheap — set and complete inline; don't manufacture a session

A task's *existence in rmap* is decoupled from *how it gets executed*. Creating one
(`rmap new`) and completing it (`rmap status <id> done`) are lightweight ledger
writes — seconds, a handful of tokens. Neither warrants a separate session, a
dispatch, or a round of "should this even be a task?" deliberation.

When a task is small and you're already in the relevant code, the cheapest correct
path is: **do it inline now, then `rmap status <id> done --implemented "…"` in the same
motion.** Reserve a separate dispatched/cloud-agent session for work that genuinely
earns it — large, risky, parallelizable, or (under a dogfooding mandate) a change to
the orchestrator's own surface. Capturing a discovery as a *pending* task is also fine
and cheap — but **capture ≠ dispatch, and a task ≠ a session.** Hand-done inline tasks
honestly leave `verified` unset (no independent grader ran).

**Failure mode this kills:** treating every rmap entry as a dispatch-and-verify cycle,
or looping in discussion over whether to file/dispatch, when setting + doing +
marking-done inline costs less than the deliberation. Set it, do it (or defer it),
mark it done — don't burn time, tokens, and circles on the ceremony around it.

### 🚨 Right-size tasks — a task is a *dispatch unit*, not a *changelog line*

**The unit of an rmap task is one implement→review→land cycle's worth of coupled
work — not the smallest namable edit.** Every dispatched task pays a full cycle's
overhead (worktree, implementer run, cross-family reviewer, merge, audit). A task
too small to justify that overhead is a manufactured session: it spends an entire
loop to land a one-liner. The 223 lesson (a whole dispatchable task filed for a
moduledoc edit) is the canonical anti-pattern — **that work gets done inline, the
instant you spot it, never filed.**

**Before creating OR splitting a task, apply the coupling test — split on coupling,
never on size:**

1. **Does task B only delete / fix up / wire what task A orphans?** Then B is not a
   task — it's the second half of A. Fold it in. (Tell: B `depends_on` A *and* B's
   files are the ones A stops using; or A's own acceptance criteria already entail
   B's deliverable. Worked example: the CapabilityScore-delete task was redundant —
   its parent's criteria already said "no magic weights remain in the routing
   path," which *is* the deletion. Merged.)
2. **Would one reviewer naturally verify both in a single pass over a single diff?**
   Then they're one dispatch. Don't make the merge train run twice for one logical
   change.
3. **Is it ALL of: D≤2, ≤30 LOC, ≤3 files, no public-surface change?** Then it's an
   *inline* task, not a *dispatch* — do it now and `rmap status … done`, per "rmap
   is cheap" above. Don't file it for later; don't route it through an agent.

**The opposite anti-pattern is equally wrong — do NOT grab-bag.** Combine only
*coupled* small tasks (shared files, one orphans the other, same atomic change).
Two small tasks that are merely both small but touch disjoint files and unrelated
concerns stay separate — bagging them creates a task a reviewer can't verify as one
thing. **Coupling is the merge criterion; size is only the inline-vs-dispatch
criterion.**

**Failure-mode tell — about to file/keep a task whose entire body is "delete the
thing the previous task stopped using," or whose deliverable is already entailed by
a sibling's acceptance criteria? STOP. Fold it into the sibling. About to merge two
small tasks that share no files and no dependency just because both are small? STOP.
That's a grab-bag — keep them separate.**

### Batches are derived, not declared

`rmap next-bundle` returns a session-sized **bundle** — a set of related pending tasks. A *batch* is a finer-grained slice of that bundle: the executor groups bundle tasks by `depends_on` into successive layers of disjoint work (per `workflow-philosophy.md` § "Batched Execution"). There is no `rmap batch` command — batch derivation is the executor's job, not the source-of-truth's. Hierarchy: phase ⊇ bundle ⊇ batch ⊇ task.

### Parallel-dispatch surface (`rmap ready` + the orchestration fields)

When you need *the set of tasks I can dispatch in parallel right now* — not "a session's worth" (`next-bundle`) and not "the single best" (`next`) — use **`rmap ready`**. It returns every `pending` task whose deps are all `done`, which is **mutually independent by construction** (a pending task with all deps done can't depend on another pending task), so the whole set is safe to fan out at once. `rmap ready --bundle <B>` is the dispatchable layer-0 of a bundle — the parallel batch `next-bundle`'s serial chain can't express. Five facts the orchestrator reads instead of re-parsing every task body:

- **`assignee`** (creation-time field, validated against `human|claude|codex|cursor|grok|antigravity|pi|droid`): **THE agent-routing field** — which agent executes the task. Orchestrators route on it (`--fields id,assignee,markers`), and `rmap delegate` defaults `--to` from it. `assignee = "human"` means "not for autonomous dispatch" — consumers skip it. Don't overload `model` (a free-text LLM id) or the `cx`/`csr` markers (filter/discovery tags) for routing. **Set `assignee` at creation** (`rmap new` / `--from-stdin`) or **reassign later** via `rmap assign <id> <agent> [--model <m>]` — an unset assignee carries no routing intent, so the interactive `rmap delegate` errors (pass `--to`) and an autonomous consumer falls back to *its* configured default dispatch agent rather than your intent. Pick the agent when you file the task; use `rmap assign <id> none` when the work is genuinely for hand-build only.
- **`dep_layer`** (computed, on every `--json`): longest-path depth over the in-repo dep graph. Within a result set the lowest `dep_layer` present is the current parallel wave; higher layers are later waves — makes `next-bundle`'s topo chain self-describing.
- **`unlocks`** (computed, on every `--json`): count of tasks that transitively depend on this one — the size of its `rmap blocks <id>` set. Turns hand-guessed unlock leverage (the `U` score's leverage component) into a graph fact: a high-`unlocks` pending task gates a lot of downstream work. Like `dep_layer` / `eff`, computed at read time, never persisted. Use `rmap blocks <id>` to see *which* tasks, `unlocks` to rank by *how many*.
- **`handbuild` marker + `--dispatchable`**: `--dispatchable` (on `ready` / `list`) drops `handbuild`-marked tasks. **UI/LiveView/CSS work is NOT handbuild by default** — incremental UI against an existing design system or a frontend-design doc is normal headless dispatch. Reserve `handbuild` for the genuine minority where a human-in-browser is required: net-new visual identity with no design spec to build against (exploratory look-and-feel / motion / brand). Everything else — backend and spec-anchored UI alike — is headless-dispatchable by default.
- **`touches`** (creation-time field): the broader *involvement hint* — files a task may read or write, typically a superset of `files_to_modify` (the write target). Consumer collision rule (you dedupe; rmap doesn't enforce): two tasks conflict iff `(touches(A) ∪ files_to_modify(A)) ∩ (touches(B) ∪ files_to_modify(B)) ≠ ∅`. Unioning both fields keeps `files_to_modify` respected even when a task's `touches` isn't a perfect superset — `touches` is "typically," not guaranteed, a superset. Set it via `rmap new --from-stdin`.
- **`--fields a,b,c`** (on `ready` / `list`): projects `--json` to a bare array of just the named keys per task — token-cheap for an orchestrator that only needs `id,status,eff,depends_on,dep_layer,touches`. Implies `--json`; unknown name exits 1.

### D/B/U mapping

rmap's scoring **is** the `task-prioritization.md` framework, executable:

- `scores = { d, b, u }` on each `[[task]]` ⇒ the `[D:X/B:Y/U:Z]` you'd otherwise hand-write
- `eff = (b + u) / (2 × d)`, computed at read time, never stored — same formula, same tiers (`≥2.0 🎯 / ≥1.5 🚀 / ≥1.0 📋 / else ⚠️`)
- `scored_at` older than 30 days renders an `Eff:W?` decay suffix

Set scores in `tasks.toml` (via `rmap new` or editing the file); never hand-format the bracket — `rmap render` produces it.

### Status & marker vocabulary

- **status:** `pending | in_progress | blocked | done | superseded` — transitions go through `rmap status`. `blocked` requires a `blocked_reason` (set inline via `--reason "..."`; free-text, blocked-only, overwrites, and **auto-cleared when the task leaves the blocked state** — it renders inline on the blocked row in `ROADMAP.md`); `done` requires `implemented` (set inline via `--implemented "..."`, or pre-populated in `tasks.toml`; on a TTY without the flag, `rmap status` prompts). For bulk `rmap status 1,2,3 done`: the mutation is atomic — if any task is missing `implemented` AND no `--implemented` flag is given AND we're not on a TTY, the whole batch is rejected; `--implemented "..."` applies the same string to every task in the batch.
- **markers:** `parallel | cx | csr | bug | security | docs | handbuild` — `parallel` is the old `[P]`; `cx` / `csr` are the Codex / Cursor delegation markers; `handbuild` flags the narrow human-in-browser exception — net-new visual identity with no design spec (NOT routine UI/LiveView/CSS, which is dispatchable) — that `rmap ready --dispatchable` / `rmap list --dispatchable` exclude.
- **milestone status:** `pending | active | done` — distinct vocabulary from task status. Flip by hand-editing `[milestones.<name>].status` (no mutator yet); `active` milestones sort first in `rmap milestones` and are the load-bearing affordance for the "what release am I cutting next?" query.

### Milestones — first-class release lines

`[milestones.<name>]` is a fourth top-level concept alongside phases / bundles / markers. **Phase** orders work, **bundle** groups topically, **markers** modify execution, **milestone** pins a task to a release line. Milestones cross phases by design: a `v1.0` cut typically pulls from several phases.

**Milestone `description` MUST state a hypothesis.** One sentence naming what the milestone tests (e.g., *"proves Bali professionals will pay for a Bali-specific material-price tool"*, not *"data platform complete"*). Feature-checklist descriptions break the Pre-Creation Gate's milestone-fit check (`task-writing.md` § 4): without a hypothesis, no pinned task can be classified as "tests hypothesis" vs "assumes hypothesis, builds on top", and heavy moat-building drifts onto early validation milestones.

**Default at session start: pick the next task via the active milestone.** Keep exactly one milestone at `status = "active"` (the MVP/release you're cutting); plain `rmap next` then auto-biases to it — no `--milestone` flag needed. Reach for `rmap next --milestone <name>` only to override to a different release line.

- Author the table in `tasks.toml`: `[milestones.v0_1] name = "..." order = N status = "active" target_version = "0.1.0"`. `target_version` is optional free-text.
- Pin a task: `rmap milestone <id> v0_1` (or set `milestone = "v0_1"` directly). Unpin: `rmap milestone <id> none`. One milestone per task.
- Discovery: `rmap milestones` (table view with done/total counts + next-task glyph + active-first sort); `rmap milestones --json` for the agent envelope.
- Drive a release line: `rmap next --milestone v0_1` returns the next pending task in that release; composes with `--bundle`, `--phase`, `--marker`. Without an explicit `--milestone`, `rmap next` automatically biases toward tasks pinned to any `active` milestone — analogous to the existing focus-phase bias. **Focus phase dominates** milestone when the two diverge (4-tier lexicographic: focus-only > active-milestone-only); pass `--milestone <name>` to override the auto-bias to a different release.
- `rmap delegate` surfaces the milestone in `## Context` as `- Milestone: v0_1 (target=0.1.0)` so the target agent knows which release ships their work.
- `rmap render` adds a conditional `🚀 **<milestone>** ·` segment to the task row in `ROADMAP.md` — rows without a milestone render byte-identically to before.
- `rmap render` also fills an optional `<!-- MILESTONES:BEGIN -->` / `<!-- MILESTONES:END -->` section when present. Body shape: one markdown block per declared milestone, sorted like `rmap milestones`; each block includes `### <key> — <name>`, `target_version` (`none` when absent), status glyph + status (`🔄 active`, `⬜ pending`, `✅ done`), the hypothesis from `milestone.description`, and `<done>/<total> done` pinned-task counts. Projects without the marker pair render byte-identically to before.

### `body` vs `implemented`

- `body` = original task definition / intent (never mutated after creation — the spec at scoping time).
- `implemented` = what was actually built and why (required when `status = "done"`; `rmap show` renders both side-by-side as `body (original intent):` / `implemented (what shipped):` when present together). For trivial tasks where delivery matched the spec, `implemented = "as specified in body"` is honest and durable.

### Outcome layer: `delivered_by` + `verified` + `shipped_in`

Three optional transition-time fields next to `implemented`, all set by `rmap status <id> done`. The triple answers who built it, whether a grader agreed, and where it landed:

- `delivered_by = "<agent>"` — which agent or instance actually shipped the task (free-text, unvalidated, like `model`). Answers "who built this?" as a queryable fact without parsing prose. Settable via `--delivered-by <agent>` on `done` transitions; overwrites on re-set.
- `verified = true` — independent evaluator confirmed the task. Two-state: `true` = a check separate from the implementer passed (verification stack green, code-review approved); absent = not yet graded (hand-built, bootstrap, merged directly). Settable via `--verified` presence flag on `done`; to clear, edit `tasks.toml` directly. Encodes evaluator-separation as a fact, not as a status — `done` means "an implementer said so", `verified` means "a grader agreed".
- `shipped_in = "<sha>"` — where the work landed (commit SHA / PR ref, free-text, unvalidated). Settable via `--shipped-in <sha>` on `done` transitions; overwrites on re-set. No sha-shape validation, no git auto-derivation — the caller supplies it.

All three surface in `rmap show`, `rmap list` JSON / `data.json` (via `ExportedTask`), and `rmap diff --verbose`. `rmap list --delivered-by <agent>` filters the roadmap into a per-agent delivery ledger (status-agnostic — matches the field, not just done tasks). `rmap doctor` emits a soft `ClaimedNotGraded` advisory for `done && verified.is_none()` ("claimed, not graded") — always exit 0, hand-built tasks are legitimate. Graph-health advisories (`bottleneck`, `isolated_node`) flag high-leverage gating tasks and disconnected/off-milestone nodes — also soft, exit 0; tune the bottleneck cutoff with `--bottleneck-min` (default 3). All three stay off `StdinTask` / `NewTaskFields` on purpose; they are outcome facts, not creation-time intent.

### Pinning an LLM model per task

`model = "<model-id>"` on a `[[task]]` records which LLM should do the work — the *value* is free-text and unvalidated (model IDs churn, so no closed set). `rmap delegate` surfaces it as a `- Model:` bullet in the prompt's `## Context` so the target agent knows which model to run. Settable at creation via `rmap new` (interactive + `--from-stdin`) or a direct edit.

**`model` is required (presence, not value) on a live agent-assigned task.** `rmap validate` hard-errors (exit 1, agent-grep `missing model`) when a `pending`/`in_progress` task has `assignee` set and != `"human"` but no `model` — harness hard-rejects a dispatch that resolves to no model (it never falls through to the agent CLI's ambient default), so rmap refuses to author one. The mutators inherit this (validate-then-write): `rmap new --assignee <agent>` on a model-less task fails before write; `rmap assign <id> <agent>` without `--model` fails the same way. Pin a model whenever you set an agent assignee on a live task. Terminal tasks (`done`/`superseded`/`blocked`) and assignee-unset / `human` tasks are exempt.

`rmap assign <id> <assignee> [--model <m>]` sets routing on an existing task (creation-time fields otherwise only writable via `rmap new` or hand edit). `rmap assign <id> none` or `rmap assign <id> human` clears both `assignee` and `model` for hand-build work — `--model` is forbidden on that path.

The three-way split — don't conflate them:

- **`assignee`** = which *agent* executes the task (validated agent set; THE routing field consumers route on)
- **`model`** = which *LLM* that agent runs (free-text pin; never an agent name)
- **`delegate --to`** = explicit render-time override of `assignee` for one prompt (omit it to honor the stored routing intent)

A fourth, advisory dimension sits alongside these: **`domains`** = a free-text list of capability tags on a `[[task]]` (e.g. `domains = ["otp", "ecto"]`), unvalidated and no closed enum — the *downstream consumer* owns the vocabulary (harness maps them to its `CapabilityDomain` for per-`{agent, domain}` capability scoring). Unlike `assignee`/`model`/`--to`, `domains` does not route a single dispatch — it labels the task so a consumer can group outcomes by domain and move dispatch from explore to exploit. Settable at creation via `rmap new` (interactive + `--from-stdin`) or a direct edit; surfaces on every `--json` payload, in `data.json`, and as a `- Domains:` bullet in `rmap delegate`'s `## Context`.

### Migrating a hand-edited ROADMAP.md

Run `rmap import` — it emits a paste-ready prompt that walks an agent through converting one or more hand-edited `ROADMAP.md` files into `roadmap/tasks.toml` (schema, marker pairs, validate → render → diff-check). One-time, LLM-driven; the prompt carries the detail so this include doesn't have to.

### Cross-references

- `task-prioritization.md` — the D/B/U framework, tiers, ceremony floor, exclusions that rmap executes
- `task-writing.md` — how to write a task's `body` / `acceptance_criteria`; the `rmap new --from-stdin` shape
- `workflow-philosophy.md` § "Batched Execution" — canonical rule for the batch derivation referenced in § "Batches are derived, not declared"


> **Trimmed 2026-05-30.** The previous version `@`-imported 14 includes + the 43 KB harness-driver SKILL (~44k tokens always-on), which drove compulsive re-reading on Opus 4.8. The eager floor is now the three above — `critical-rules` (guardrails), `code-style` (KPIs), `rmap` (roadmap decision layer, used every session). Harness workflow (`harness-workflow.md`) is load-on-demand below — same adoption path as other repos: `@~/.claude/includes/harness-workflow.md`. `response-conventions` is inherited from `~/.claude/CLAUDE.md`, not re-imported here. Everything else is **load-on-demand** — pull it only when the trigger matches.

## Load-on-demand (don't auto-load — read the file or invoke the skill when the trigger hits)

| When you need… | Load |
|---|---|
| `mix test.json` flags / jq recipes | Skill `elixir:ex-unit-json` |
| `mix dialyzer.json` flags / fix_hints | Skill `elixir:dialyzer-json` |
| `mix` / `ex_dna` / `ex_ast` command surface | Skill `elixir:development-commands` |
| rmap CLI: status/score/new/render/delegate | Skill `tasks:rmap` |
| D/B/U scoring, ceremony floor, task-writing | Skill `tasks:roadmap-planning` + `@~/.claude/includes/task-writing.md` |
| Session-per-phase / batched-execution / evaluator-separation rules | `@~/.claude/includes/workflow-philosophy.md` |
| Worktree-per-branch workflow | `@~/.claude/includes/worktree-workflow.md` |
| Harness delegate→verify→repair→land workflow (portfolio adoption) | `@~/.claude/includes/harness-workflow.md` |
| Driving harness as a consumer (dispatch patterns, result shapes) | `@skills/harness-driver/SKILL.md` |
| Phoenix project setup / gen.auth | Skill `phoenix:phoenix-setup` |
| Net-new / redesign frontend surface (distinctiveness IS the goal) | Skill `frontend-design:frontend-design` — **not** for incremental work in the existing dashboard design system (match `tokens.ex` + `components.ex` patterns instead; skill is at most a reference) |
| The "message across instances" (philosophical anchor) | `@~/.claude/includes/across-instances.md` |

**Situational skills** (invoke via Skill tool when trigger matches; don't auto-load): `elixir:reach` (PDG/SDG, `mix reach.otp`), `elixir:web-command` (browser/dashboard work), `elixir:agent-economy` (descripex surface), `elixir:elixir-setup` (dep-stack / alias edits).

## Elixir methodology (the non-obvious mandates — compressed from development-philosophy.md)

The full include is verbose and mostly restates mainstream Elixir. These are the bits the model would otherwise get wrong:

- **`@spec` on every function — `def` AND `defp`.** Not the community publics-only default. Configure `{Credo.Check.Readability.Specs, [include_defp: true]}`. Suppress macro-generated `defp` per-callsite, don't drop the check.
- **Doctests are documentation, not tests.** Happy-path / API-shape examples only. Edge cases, boundaries, unions, error paths → ExUnit `describe` blocks. A second doctest "to cover the empty case" is the failure mode — write an assertion instead.
- **`TODO:` prefix for all temporary code / "for now" / "in production" notes** so Credo tracks the debt. No prefix = invisible debt.
- **No IO in `@doc` examples.** `@doc` demonstrates API usage, not console output.
- **Library-first / precedent-first (anti-hedging).** Before calling a cost a real trade-off (case-conversion, option validation, wire-format friction) → check hex.pm. Before objecting a macro/DSL "could grow knobs" → name the specific Elixir precedent that fails the same way (Phoenix.Router, Ecto.Schema, NimbleOptions, Ash) or accept it. Generic FUD without a named failure pattern is hedging.
- **Internal-API markers:** `defp` first; `@doc false` for must-be-public-but-internal; `@moduledoc false` on a whole `MyLib.Internal` module; `@opaque` for tokens/handles whose structure is implementation detail.

## rmap is ours

The `rmap` CLI (the roadmap substrate `roadmap/tasks.toml` uses) is a sibling Rust project we own at `../rmap/` (`/Users/efries/_DATA/code/rmap/`). If the roadmap workflow needs a CLI change — new field, query, render, or `delegate --to` target — edit it there; don't work around a gap in harness. The `tasks:rmap` skill is the usage contract; `../rmap/` is the source.

**AI driver surface (canonical for orchestrators):** `@skills/harness-driver/SKILL.md` — **load on demand** when driving harness as a consumer. Stable contract for delegation patterns, non-delegatable handling, result interpretation, sharp edges. Any change to public driver surfaces must update it.

> **Two harness skills are canonical HERE, not in `~/.claude/includes` — propagate with `scripts/sync-harness-skills.sh`.** `priv/includes/harness-workflow.md` (the portfolio implement→review→land contract) and `skills/harness-driver/SKILL.md` (this driver surface) are the source of truth. The general marketplace sync (`claude-marketplace/scripts/sync-skills-from-includes.sh`) **deliberately excludes** them. After editing either, run `scripts/sync-harness-skills.sh` — it fans the workflow include out to `~/.claude/includes/` **and** both `plugins/harness/skills/*/SKILL.md` in the marketplace (frontmatter preserved, idempotent, `--dry-run` to preview). Skip it and the installed include + marketplace skills silently drift from the source.

## Commands

Toolchain: **Elixir 1.20.0 / OTP 29** (asdf) — pinned by the repo-local `.tool-versions` (`elixir 1.20.0-otp-29` / `erlang 29.0.1`). `mix.exs` floors at `~> 1.18`; a repo-local `.tool-versions.1.18` (1.18.4/OTP27) pins the lower-bound compat target — `cp .tool-versions.1.18 .tool-versions` to build against it. Postgres required for the Oban dispatch layer.

> **Sync `development` before committing when auto-land is on.** With `landing_policy: :auto`, the lander is a *second committer* to `origin/<target>` — it ff-pushes from a detached worktree and deliberately **never touches your checkout**, so your local `development` ref drifts behind origin after every autonomous land. **Before any commit/push, `git fetch origin development && git rebase origin/development`** (or `git pull --rebase origin development`) — rebase, because you'll often have local commits the lander doesn't. Skip it and you get a stale base / non-ff push reject. A clean rebase → `git push origin development` is the completing step; just do it. If the rebase still has unresolved conflicts or the push is non-ff, stop and surface it — don't force-push a shared branch.

| Task | Command |
|---|---|
| Run the node | `iex -S mix` — boots the app, Oban (Postgres), and the dashboard on `http://localhost:4018` (routes `/harness`, `/harness/oban`, `/harness/mcp`, `/tidewave/mcp`). **Long-lived; the user starts it manually — don't boot it yourself.** |
| First-time DB | `mix ecto.setup` (creates, migrates, and runs `priv/repo/seeds.exs` when present). DB name/user overridable via `HARNESS_DB_NAME` / `HARNESS_DB_USER` (defaults `harness_dev`, `$USER`). |
| Tests | `mix test.json` — AI-friendly JSON output; **use over bare `mix test`** (load `elixir:ex-unit-json` for flags/jq). `:integration` tests (real agent CLIs, live DB) are **excluded by default** — add `--include integration`. |
| Single test | `mix test.json test/harness/run_test.exs:42` · re-run only failures: `mix test.json --failed` · coverage: `--cover`. |
| Fast gate | `mix check.fast` — `format --check-formatted` + `compile --warnings-as-errors` + `credo --strict`. |
| Pre-commit gate | `mix precommit` — adds `doctor --raise`, `test.json --cover --cover-threshold 80 --exclude integration`, `sobelow`. Hook-bound (180s); **dialyzer is deliberately not here** (cold-PLT timeout). |
| Before PR / handoff | `mix precommit.full` — `precommit` + `dialyzer.json`. (No CI workflow exists yet — this is the only mergeable-bar gate.) |
| Sync harness skills | `scripts/sync-harness-skills.sh` (`--dry-run` to preview) — after editing `priv/includes/harness-workflow.md` or `skills/harness-driver/SKILL.md`, propagate to `~/.claude/includes/` + the marketplace `harness` plugin skills. The general marketplace sync excludes these two. |

**Per-edit hooks already run this stack** (`format`, `compile`, `test.json`, `credo`, `dialyzer.json`, `sobelow`, `doctor`) on every touched file — don't re-run a check the hook just graded. Full-suite `precommit.full` earns its cost only before a PR/merge, after `mix deps.get`, or on a branch switch (see global CLAUDE.md § "Don't Re-Run Hook-Driven Checks").

## What This Is

`harness` is an OTP-native Elixir engine an **AI orchestrator drives end to end**: pull a task from the rmap roadmap → **implementer AI** works in an isolated git worktree → **reviewer AI** (cross-family) reviews, runs the project's checks itself, fixes inline, and renders the verdict → **MERGE** (lander rebase + push) → **audit AI** post-merge. Consumer surfaces: Elixir API (IEx / tidewave / another BEAM process), the Phoenix LiveView dashboard, and an MCP server. It is a long-running OTP node that orchestrates **N registered target projects** (Elixir, Rust, anything an agent can check) concurrently.

**Primary user is an AI agent, not a human** — harness is the OTP-native automation of the worktree → implement → review → merge → audit loop this repo's owner runs by hand (see `~/.claude/includes/worktree-workflow.md` for the manual analogue).

**Not a wrapper around one agent.** The `AgentAdapter` behaviour (Task 3) is a deliberately thin contract: *invoke* an agent, *capture its raw output*, declare capabilities — nothing more. **No normalized event model**: the consumer is an AI that reads each agent's raw JSON natively; harness decides "did the job succeed?" from the **reviewer AI's verdict artifact**, never from the implementer's self-reported result.

## Architecture

- **Elixir / OTP, not TypeScript.** harness *is* N concurrent supervised agent runs needing crash isolation, timeouts, retries, observable state. One run = one supervised `gen_statem`; one batch = a `DynamicSupervisor`.
- **Core loop.** rmap task → implementer AI in isolated worktree → commit → **reviewer AI is the gate** (reviews against acceptance criteria, runs the project's checks itself, fixes inline, writes `.harness/review.json` verdict) → approve ⇒ done ⇒ merge ⇒ post-merge audit AI; reject ⇒ failed, task back to queue. Implementer/evaluator separation is agent/agent (cross-family), not agent/script — see "The Agent-Gate Workflow" below.
- **Thin adapter pattern.** One adapter per agent: invocation + raw capture + capability declaration. Behaviour `Harness.AgentAdapter` — required callbacks `capabilities/0` + `rule_channel/0` + `build_command/1`; `classify_message/2` + `terminate/1` default via `use Harness.AgentAdapter` + defoverridable. `AgentAdapter.invoke/2` does the generic Port spawn. `build_command/1` threads caller-controlled env (`Invocation.env`, set/scrub pairs → Port, Task 25). Harness-owned rules delivered ahead of `build_command/1` by `AgentAdapter.attach_rules/2` (Task 39), dispatching on `c:rule_channel/0`: `:system_prompt_file` (Claude), `:codex_ephemeral_file` (Codex/Pi), `:cursor_ephemeral_file` (Cursor), `:prompt_preamble` (Grok/Antigravity), `:none` (test doubles). Every adapter must pass `Harness.AgentAdapter.ConformanceCase` **unchanged** — a leak gets fixed in the behaviour, not patched in the adapter.
- **No agent-output parsing.** Raw passthrough is simpler *and* more robust — agents ship 40+ releases; a JSON-format change is absorbed by the AI reading the transcript, not by breaking a normalization layer.
- **Path discipline:** raw-output capture is hot-path-adjacent (allocation-light); run/batch lifecycle is warm-path OTP state; dashboard / MCP is cold-path.
- **🚨 Persistence is Ecto/Postgres, not config files or `~/.harness` terms.** `repo_enabled: true` is the **default**, and under it Postgres is the source of truth for all durable state: `Harness.SettingsStore` (operator/UI settings, cron-autonomy switches + schedule, agent/landing config — `harness_settings` table), `Harness.ProjectRegistry` (`projects` table), `Harness.ResultStore` (run records + batch results, KPI/reliability/facet aggregates), `Harness.Chat.Store` (chat sessions), and Oban's own job tables. Ecto schemas live under each store's `schema/` dir; migrations in `priv/repo/migrations/`. **`config :harness, …` is a seed + live-cache layer, NOT the store** — `Harness.Config` keeps app-env as a hot read cache that `SettingsStore` (Postgres) is the persistence layer behind, env-var-wins-over-UI-override; `config :harness, :projects` only seeds missing rows on first boot. With `repo_enabled: false` (library consumers mounting harness without a DB) the stores fall back to **in-memory ephemeral** — no file persistence either. The *only* legitimately file-based state is the per-worktree `.harness/*.json` artifacts (`review`/`audit`/`recovery`/`cron-plan`, mechanical read) and the `CapabilityScore` scout artifact under `~/.harness` — everything an agent would call "saved data" is a table. Reach for `mcp__tidewave__execute_sql_query` / Ecto, not a config read, when inspecting persisted state.
- **Multi-project federation (shipped, v0_5; simplified by the agent-gate rebuild).** `%Harness.Project{}` (Task 46) carries `source` (`{:local, dir}` or `{:github, url}` — Task 47), `check_command` (free-text hint handed to the reviewer AI, e.g. `"mix precommit"` — the reviewer runs and judges it itself; multi-language monorepos just describe both commands in the hint), `language` (optional atom for language-aware injected agent rules; `nil`/`:elixir` keeps Elixir guidance, other atoms suppress it), `roadmap_path`, `concurrency_cap`, `landing_policy`, `target_branch`, and `test_db_isolation_env` (default `MIX_TEST_PARTITION`; `false` / `"none"` opts out). `Harness.ProjectRegistry` is the in-memory registry **backed by Postgres** (Ecto schema `project_registry/schema/project.ex`): with `repo_enabled: true` (the default), runtime `register/1`s persist to the `projects` table and are restored at boot, and **the Postgres row wins** — `config :harness, :projects` is **seed-only on first boot** (only seeds missing rows; edit live projects in `/harness/settings` or via `priv/repo/seeds.exs`/`mix harness.seed`, never by editing config and expecting it to take). The old declarative `check_stacks`/presets/`Harness.Verification` machinery is **deleted** — see "The Agent-Gate Workflow" below.
- **Oban = dispatch layer** (Task 48): queue-per-project gives per-project concurrency caps + restart resilience (jobs survive BEAM death in Postgres). `Oban.Plugins.Cron` (Task 51) enables autonomous roadmap polling. Dashboard (Task 50): `Harness.Dashboard.Endpoint` standalone Bandit on **4018** (conditional behind `:dashboard, :enabled` + `Code.ensure_loaded?(Bandit)` so mountable consumers aren't forced into a 2nd HTTP server), Oban Web at `/harness/oban`, MCP at `/harness/mcp`, Tidewave MCP in dev — all on the one port.
- **Autonomous landing (shipped, v0_9; simplified by the agent-gate rebuild).** `Harness.Lander` is the merge-train: a run the reviewer approved on a project with `landing_policy: :auto` + `target_branch` enqueues a landing job on the project's serialized `landing_<name>` Oban queue (limit 1). The lander rebases the run's `harness/<run-id>` branch onto `origin/<target>` in a fresh **detached** worktree and fast-forward-pushes (never `--force`; the operator's checkout is untouched; **no re-verification** — the reviewer already gated the work). A rebase **conflict** is the one MERGE-node judgment call: instead of a blind re-dispatch, the lander hands the conflicted worktree to a cross-family merge-resolver agent (`Harness.Lander.Resolver`, Task 189) that reconciles the markers (keep-both by default); harness then mechanically stages, asserts zero leftover markers, and `rebase --continue`s — on **resolver failure the lander never re-dispatches**: the reviewer-approved `harness/<run-id>` branch is retained, the task is marked `blocked`, and the conflict is witnessed (a still-conflicted tree is never landed; the resolver never re-runs checks). Recovery is operator-driven `dispatch-reland` (a zero-token re-land once the conflicting change has settled) — committed, reviewed work is recovered, never thrown away and re-implemented. A successful push enqueues the post-merge audit job. `Harness.Notification` fires witness events (land / blocked) to configured sinks — read-only by design, never a gate. Run recovery: `hold`/`steer`/`resume` on the gen_statem (Task 150). Cron autonomy: master + per-project toggles, persisted in **`Harness.SettingsStore` (Postgres)** via `Harness.Cron.Settings` — switches, dispatch modes, and the cron schedule all live in one settings row, not a `~/.harness` file (Tasks 109/110).
- **Agent KPIs + capability routing (shipped, v0_10; re-keyed to reviewer outcomes).** `Harness.ResultStore` (behaviour: **Postgres** by default — `repo_enabled` is `true` — falling back to an **in-memory ephemeral** store when `repo_enabled: false`; there is no file backend) persists run records best-effort at settle time; `Harness.AgentKPI` is a pure read-only rollup (success = reviewer approved; first-attempt-pass = approved with zero reviewer fixes; duration p90; cost-to-approved). Reviewer reliability also counts rejection, no-verdict, and `approved_then_found_red` false-approval facts per reviewer/model from post-merge audit `cold_check`; routing surfaces these facts but applies no penalty, weight, or auto-exclusion. `Harness.CapabilityScore` reads agent/scout-written assessment artifacts for `dispatch-recommend`; the mechanical benchmark corpus is deleted.

## Orchestration Library — Build a Thin Core (settled, Task 2)

Core is textbook OTP (Port per run, `gen_statem` per run, `DynamicSupervisor` for batches). Adopting a niche orchestration lib adds risk, not leverage. Evaluated `opal`, `gen_agent(_ensemble)`, `altar_ai`, `ex_mcp`, and SDKs `claude_code`/`codex_sdk` — **outcome: build thin core, adopt none, uniform Ports.** Full rationale: `docs/orchestration-library-evaluation.md`.

- **None of the orchestration libs spawns/supervises an external OS process** — no Port in any of them; they coordinate *in-process* LLM agents, harness orchestrates *external* headless CLIs.
- **`claude_code` / `codex_sdk` are CLI wrappers**, not native reimplementations. An SDK's headline value is a normalized event model, which harness's raw-passthrough design deliberately discards. So **uniform Ports for every adapter**.
- **Cold-path surface = dashboard + Oban Web + MCP, all on one Bandit.** Mountable into a consumer Phoenix endpoint or standalone. MCP (`Harness.Dashboard.MCPServer`, on `anubis_mcp`) exposes the descripex-`api()`-annotated driver surface (`Harness.Manifest`) as MCP JSON-RPC 2.0 over Streamable HTTP at `/harness/mcp`. `Harness.Chat.Tools` is the single source of truth for both the in-process chat dispatcher (`Harness.Chat.Session`) and the MCP surface. `Harness.Roadmap.list/2` + `next_bundle/1` let the orchestrator browse a registered project's roadmap as structured data. `Harness.Playbooks` layers orchestration recipes as compile-time-embedded `priv/playbooks/*.md`.
- **Oban = queue + persistence + cron, NOT a worker engine.** It *wraps* `Harness.Run` gen_statem: `Harness.Run.Worker` takes `{project_name, item_id, adapter_module}`, spawns the gen_statem, threads terminal state into Oban's contract. gen_statem stays load-bearing (runs are minutes-to-hours with rich live state).
- **Dispatch retry vs in-run review — keep separate.** Oban owns dispatch-level persistence/retry, and it is **crash-only mechanical** (Task 163): `Harness.Run.RetryPolicy` is pure backoff arithmetic — a settled run is never re-run by policy code. Quality outcomes are handled *inside* the run by the reviewer AI (fix-and-approve is the near-absolute default; rejection puts the task back in the queue). Open-source Oban has no cross-queue global cap; effective ceiling = sum of `project_<name>` queue limits.
- **`Harness.AgentRegistry` is a soft hint, not a contract** (Task 40, option (b)). Unavailability lives in GenServer state only — no persistence/TTL; restart clears it **by design**. It's a *latency optimization*; *correctness* lives in Oban. Rationale: `lib/harness/agent_registry.ex` `@moduledoc`.

## The Agent-Gate Workflow (settled, 2026-06-03 — THE architecture, do not re-litigate)

**The workflow:** `worktree → implementer AI → reviewer AI (THE GATE) → MERGE → audit AI`. There is **no mechanical test runner / verification gate** in harness. The reviewer AI runs the project's checks itself — having harness also run them mechanically added wall-clock, crash surface, false verdicts, and config burden for zero added judgment.

> **Status:** rebuild landed 2026-06-03 (hand-built). `docs/agent-gate-workflow.md` is the spec.

**Per-run test DB isolation (Task 320):** the implementer and reviewer Ports get a run-unique, DB-name-safe test partition env var. Default is `MIX_TEST_PARTITION`, matching Phoenix/Ecto's generated `config/test.exs` pattern; projects using another variable set `%Project{test_db_isolation_env: "NAME"}`, and projects with their own isolation set `false` or `"none"`. This restores the per-worktree DB isolation lost when the agent-gate rebuild deleted `Harness.Verification` / `CheckStack`; the reviewer still runs checks and remains the gate.

**The principle (extends 2026-06-02's "Judgment Lives in Agents"):** *everything that interprets meaning* — is the work good, why a run failed, what an empty diff means, whether code satisfies acceptance criteria, whether the build/tests pass *in a way that matters* — **is an agent's job, never harness code.** Harness code is mechanical substrate only: worktrees, git, Ports, Oban persistence, counters, timers, reading the reviewer's verdict file.

> ## 🧭 THE MANTRA — count facts in code; write the *meaning* of facts with an AI.
>
> This is the leitmotif of every harness session. Read it before you touch this codebase; recite it when you design, review, or refactor.
>
> Harness code may **count** a fact: `run_count`, summed tokens, a duration, a file's bytes, a git ref, a queue depth. It may never **judge** the fact: *who is good at this work, why this run failed, whether this code is good, whether this run is worth watching, which agent to route to.* Judgment is written by an agent — into a verdict artifact, an assessment file, a prompt's reasoning — never computed by harness.
>
> **The failure mode is not just "a classifier in code." It is harness counting the facts AND computing their meaning.** When you see aggregation that *fuses* facts into a verdict, score, ranking, or route — magic weights (`0.5·x + 0.3·y`), percentile gates, keyword classifiers (`~r/security|bug/`), staleness decay, "is this high-stakes enough" branches — **that is judgment wearing arithmetic's clothing.** Delete the arithmetic; persist the raw facts; have an agent write the judgment from them, on demand or as a cached artifact. The reviewer already writes per-run `ratings` — do not let harness *recompute* a verdict from those numbers; an AI that reads the raw records judges better than any formula, and explains itself.
>
> **The test, every time:** is this code *counting* (mechanics — keep) or *deciding what the count means* (judgment — an agent writes it)? When in doubt, it's judgment. The proof is in the git log: ~1,400 LOC of KPI/score/route arithmetic and every run-lifecycle false-verdict bug came from harness computing meaning it had no business computing.

**The evidence that settled it:** every run-lifecycle bug from 2026-05-26 → 06-03 (tasks 153–163, 168, 169, 171, 172, the task-41 verifier crash, the task-172 failure) traced to the *harness verification/lifecycle machinery* — false reds, false greens, verifier crashes, timeout misconfig, preset gaps. Zero traced to an agent's judgment. 32 salvage/repair/fix commits in 257.

**The stages:**

- **Implementer AI** — works in the isolated worktree, commits. Its self-report is never trusted.
- **Reviewer AI (cross-family, mandatory, THE gate)** — gets worktree + task + acceptance criteria + implementer transcript + diff stat + the project's `check_command` hint. It reviews, **runs the checks itself**, fixes inline (own edits, own commits), then writes `.harness/review.json`: `{"verdict": "approve"|"reject", "report": "...", "checks": {...}, "concerns": [], "facets": {...}, "skills": {...}, "ratings": {...}}`. Harness mechanically reads the file: approve → `:done` → merge; reject/missing → `:failed`, task back to queue. The reviewer-authored `checks`/`concerns` surface warning facts on approve, never an auto-block; skills/ratings feed AgentKPI.
- **MERGE** — lander: fetch → detached worktree → rebase onto `origin/<target>` → ff-push. No re-verification.
- **Audit AI (post-merge, batched, best-effort)** — third-family agent audits the unaudited commit range on an intentionally un-warmed target-branch worktree, runs the project's clean-build/check itself, writes the `cold_check` fact in `.harness/audit.json`, fixes hygiene inline, commits `audit(...)`, pushes. Harness never runs that build or reads an exit code. A red cold check files a blocked follow-up task + loud notification and records `approved_then_found_red` on the approved run for reviewer feedback, never a revert, unmerge, gate, or auto-down-weight.

**Rules for every session:**

- A run-lifecycle bug is fixed by **moving judgment into an agent prompt or verdict artifact** — never by adding a branch/regex/filter/classifier to harness code.
- Do not reintroduce: `Harness.Verification`, `Harness.CheckStack`, presets, verdicts, `:verifying`, baseline anything, repair loops, semantic gates, quota regexes, `review_green`, `max_review_iterations`, lander re-verification, the mechanical benchmark corpus.
- What stays code (the test: is it mechanical?): worktrees, git, Ports, Oban persistence, counters, timers/watchdogs, reading `.harness/review.json` / `.harness/audit.json` facts such as `cold_check`.

## Agent Headless Entry Points (domain reference)

| Agent | Headless invocation | Raw output format |
|---|---|---|
| Claude Code | `claude -p` | `--output-format stream-json` |
| Cursor | `cursor-agent -p` | `--output-format stream-json` |
| Codex | `codex exec` | `--json` |
| Grok | `grok -p` / `agent` subcommand | `--output-format streaming-json` |
| Antigravity | `agy -p` | none (plain text) |
| Pi (pi.dev) | `pi -p` | `--mode json` |

All six driven over OTP Ports — uniform, no per-agent SDK. harness captures raw, never parses/normalizes. **Exit code is unreliable**: derive *termination* from Port close + timeout guard; derive *success* from the reviewer AI's `.harness/review.json` verdict — never `$?`, never the implementer's self-report.

**Three-axis adapter contract** (don't conflate):
- **Agent vs model — pin the model per run.** Each adapter threads `Invocation.model` → its CLI's `--model` flag (`AgentAdapter.model_args/1`), so the *agent* (`assignee`) and the *model that agent runs* (`model`) are orthogonal. This is most load-bearing for **Cursor: it is a multi-model front-end, not "the Composer agent."** Beyond its in-house `composer-*` default, `cursor-agent` fronts Opus-tier (Opus 4.8 1M), Sonnet, GPT, Gemini, Grok, and Kimi models — so a `cursor` dispatch pinned to an Opus 4.8 model id is a full Opus-tier implementer/reviewer — **route Opus-grade tasks to cursor, not just to claude.** Pin it on the rmap task (`model = "<id>"`); with no task pin, the operator-set per-agent default fills in (`Config.agent_model/1` ← the `{:agent_model, agent}` "Agent models" settings card), and an unset default is **rejected, never silently run on the agent's CLI default** — a model-capable adapter that resolves to no model fails the dispatch with `{:model_required, agent}` (`AgentAdapter.invoke/2` + the dispatch/reviewer fail-fasts; the guard against a sticky premium CLI default burning the budget on every later run). So the implementer precedence is **task `model` → `{:agent_model, agent}` → REJECT**; the **reviewer** has no task-pin axis, so its model comes *solely* from `{:agent_model, agent}` for the selected reviewer adapter's agent (`Run.reviewer_model/1`, Task 256 — a model-capable reviewer with no configured model → `{:model_required}`, rejected before the reviewer Port spawns). The single exemption is **antigravity** (`Capabilities.model_families: []`, its `agy` CLI has no `--model` flag): it declares itself model-*incapable* and so legitimately runs model-less. Model IDs churn — never trust a hardcoded roster; read the live per-agent catalog from the node (`model_availability-list_available_models`, `model_availability-refresh_catalog` to re-poll the CLIs, `model_availability-list_blocks` for what's blocked). For the live routing picture (per-agent load, success/first-pass rates, per-domain capability ratings, which premium models are blocked) read it from the running node — `result_store-aggregate_by_agent` + `agents-list` + `model_availability-list_blocks` — never a count hardcoded here.
- **🚨 Dispatch routing — do NOT dispatch to the `claude` adapter; want gpt-5.5 → use `codex`.** The orchestrator already runs on the Claude Max subscription, so dispatching implementer/reviewer runs to the **`claude` adapter double-bills that same subscription and races its limits** — don't pin a dispatch task to `claude` to "get a strong model." For headless dispatch prefer **`codex`, `cursor`, `grok`**. **`codex` IS how you get gpt-5.5** → `assignee = "codex"`, `model = "gpt-5.5"`. Opus-grade without claude → `cursor` on `claude-opus-4-8-*` — **but cursor-Opus draws a *monthly* token budget that exhausts**, and when spent harness's catalog still lists it as available (no auto-block), so it will route and silently degrade/fail. **If cursor-Opus is exhausted: route the work to `codex`/gpt-5.5, and `model_availability-block_model` the cursor-Opus id** (with a `blocked_until` ≈ month end) so the cron poller can't pick it.
- **Renderable vs executable**: `rmap delegate --to` now renders a native prompt for all six adapters (`claude`/`codex`/`cursor`/`grok`/`antigravity`/`pi`), so each is a first-class `Roadmap.ingest(agent: …)` target dispatched directly on its own adapter — the old non-delegatable two-step is gone. rmap can also render `droid`, but harness has **no Droid adapter**, so `:droid` is rejected at the ingest/dispatch boundary (`{:invalid_agent, :droid}` / `{:unknown_adapter, "droid"}`). Adding an executor is two-sided: an rmap-lib `--to` target (the rmap binary is ours, `../rmap/` — already done for `droid`) **plus** a harness `AgentAdapter` listed in `Roadmap`'s `@valid_agents`.
- **Worktree isolation**: all six shipped adapters declare `worktree_isolation: true`. `agy` does **not** honor Port `cwd` alone (Task 32/198) — the adapter pins the run worktree via `--add-dir <cwd>` in `build_command/1`, mirroring Codex's `exec --cd` fix (Task 41). `Harness.Run` trusts declared isolation and skips the main-checkout pollution snapshot for isolating adapters.

## Reach Is in the Dep Stack

Core is OTP-dense. `mix reach.otp` (state-machine analysis, dead replies, missing handlers, supervision topology) and `Reach.independent?` are on-point. Reach is a dev/test dep (`runtime: false`); invoke the `elixir:reach` skill for OTP introspection / static analysis here.

## Status

**ROADMAP.md (rendered from `roadmap/tasks.toml` by `rmap`) is the live source of truth — start every session with `rmap next`.** High-level snapshot, not a changelog; per-task history lives in `tasks.toml` and `.remember/`.

- **Bootstrap (hand-built):** Tasks 1–8, 23, 24.
- **Phases 1–4 (dogfooded):** all 6 adapters, conformance suite (12), resilience bundle (9/10/11), caller-controlled env (25), non-delegatable contract (31), rule injection (39), capability/availability registry (16/40), StatusView (18), structured logging (19), AuditReview grader (58).
- **Phase 7 / v0_5 (multi-project + dashboard, hand-built):** Project + ProjectRegistry (46), GitHub sources (47), template (49), Oban dispatch (48), Cron poller (51), dashboard + Oban Web on 4018 (50). (CheckStack + presets 44/45 shipped here; deleted by the agent-gate rebuild.)
- **Phase 9 / v0_7 (chat orchestrator):** Manifest (75), Chat.Session (76), MCP server on anubis_mcp (79), Chat.Claude subscription-OAuth backend (82), ChatLive + tokens (78). Task 77 (hand-rolled Anthropic client) **deleted as superseded** — violated "Claude subscription, not API" + library-first. **Library-first rule reasserted.**
- **v0_8 (dashboard operator UX) + v0_9 (autonomous landing) — done:** flat `dispatch__task`, run kill (94), per-stack `workdir` (92), chat persistence (93), merge-train lander + resilience (100/101), witness notification sinks (102), `dispatch__await` (103), cron autonomy toggles (109/110/111), reflex floor (112), run recovery hold/steer/resume (150), per-project landing policy (155).
- **v0_10 (agent KPIs & capability routing) — done:** AgentKPI + dashboard (114/115), capability domains/scoring/routing (116–122), Postgres result store (137/139). Re-keyed to reviewer outcomes by the agent-gate rebuild; the benchmark corpus + agent-eval corpus task (151) were deleted/superseded.
- **v0_11 (reviewer-pair lifecycle, phase 15) — superseded:** `:reviewing` state (161), `review_green` + empty-diff routing (162), deletion pass (163) shipped, then the agent-gate rebuild (2026-06-03) absorbed and replaced the whole design (`review_green` deleted, review made mandatory). Tasks 164/166/169/170/172 superseded.
- **v0_12 (agent-gate rebuild + post-merge audit) — landed 2026-06-03, hand-built:** run-lifecycle rewrite (reviewer artifact gate), `Harness.Audit` + `Harness.Audit.Worker`, lander simplification, KPI re-keying. Confirm current state via `rmap next` — this list drifts.

## Dogfooding — harness Builds harness

From the core loop onward, harness is developed *by* harness. **Once bootstrap is `done`, every remaining pending task is delivered by dispatching it through harness.** Hand-build only what harness cannot yet do for itself. Runbook: `docs/dogfooding-workflow.md` (harness-incubator specifics + script template); general harness workflow contract (adopt via @ import in any repo): `@~/.claude/includes/harness-workflow.md`. Driver reference: `@skills/harness-driver/SKILL.md` (load on demand; changes to `AgentAdapter.*` / `Run.Supervisor` / `Batch` / `Roadmap` / Invocation/result shapes must update it).

- **Roadmap = harness's own test corpus.** A task harness fails to deliver is a harness bug, filed via `rmap new`, not worked around by hand-building.
- **🚨 Right-size every task to ONE dispatch cycle — split on coupling, never on size.** A task is one implement→review→land unit, not the smallest namable edit; each dispatch pays a full loop's overhead, so a sub-threshold task is a manufactured session (the 223 moduledoc-edit lesson — that gets done inline, never filed). Before filing or splitting, apply the coupling test from `rmap.md` § "Right-size tasks": if task B only deletes/wires/fixes what task A orphans (or A's acceptance criteria already entail B's deliverable), B is the second half of A — fold it in (worked example: the CapabilityScore-delete task collapsed into its parent, whose criteria already said "no magic weights remain"). But do **not** grab-bag — merge only *coupled* smalls (shared files / one orphans the other), never two unrelated smalls just because both are small.
- **Evaluation stays separate — agent vs agent.** Dispatched agent = implementer; a cross-family reviewer AI = grader. Done = reviewer approved, never the implementer's self-report.
- **A reject isn't stop-the-line.** The reviewer fixes what it can inline before deciding; a rejected run puts the task back in the queue for re-dispatch. Manual salvage per `docs/dogfooding-workflow.md` is the fallback when the reviewer rejects.
- **🚨 Under auto-land, check `origin` before calling a task "not landed" — your local checkout is stale.** The lander ff-pushes to `origin/<target>` and **never touches your checkout**, so after an autonomous land your local `tasks.toml` still reads `in_progress` for a task already `done --shipped-in` on origin. **Reading stale local status as "the run didn't land" is the trap** — it provokes a reset-to-`pending` + re-dispatch that *duplicate-lands shipped work*. `git fetch origin <target> && git rebase` (the "Sync development" rule above) — or read `git log origin/<target>` / `result_store-list_run_records` — **before** mutating the roadmap. (Observed 2026-06-12: runs 246/249/251 had landed cleanly; a stale-local misread caused a re-dispatch that double-landed task 246.)
- **🚨 Recover, don't redo — committed work is paid for.** Once you've confirmed against `origin` a run genuinely didn't land: a run that committed to `harness/<run-id>` already cost implementer tokens, and the `ResultStore` record + branch survive teardown. Recover via `dispatch-reland` (approved-unlanded — land-cap/conflict, zero tokens), `dispatch-rereview` (review-stage failure, zero implementer), or `dispatch-resume_failed` (implement-stage, implementer continues). Reset-to-`pending` + fresh dispatch is correct **only** for a run with no committed branch *and* no settled record. Full decision table: `@~/.claude/includes/harness-workflow.md` § "Recover, Don't Redo".
- **Hand-built exceptions:**
  - *Scaffolding that reshapes harness's own runtime* (supervision tree, dep stack, Endpoint) **while the run lifecycle itself is in flux**. A new phase that only adds features on stable surfaces does **not** earn a hand-build window.
  - *Tiny tasks* — ALL of (a) D≤2, (b) ≤30 LOC across ≤3 files, (c) no harness-surface change. Fail any → dispatch. When in doubt, dispatch.
  - *Net-new visual identity with no spec* — exploratory look-and-feel / motion / brand work where distinctiveness is the goal and no design source-of-truth exists yet (the `frontend-design` skill's territory). **Incremental UI/LiveView/heex/CSS work against an existing design system or a frontend-design doc is normal dispatch** — the old blanket "hand-build all UI" rule is retired; an in-repo design spec gives the agent something to build against, so the reviewer AI gates it like any other task.
- **Multi-project autonomy (46/48/51):** dogfooding extends to N registered projects, each with its own `check_command` + `roadmap_path`; with cron enabled it runs unattended.
