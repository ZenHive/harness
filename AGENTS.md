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

<!-- @-import: ~/.claude/includes/harness-workflow.md -->
## Harness Workflow

OTP-native **implement → review → land** loop for roadmap-driven development. An AI orchestrator drives harness; harness dispatches headless implementer agents into isolated git worktrees, then a **cross-family reviewer AI** gates every deliverable (runs the project's checks itself, fixes inline, writes `.harness/review.json`). Optional auto-landing ff-merges approved work; a post-merge audit agent sweeps hygiene.

**Promoted from** `docs/dogfooding-workflow.md` in the harness repo — that file remains the **incubator runbook** for harness-specific history, driver-script templates, and per-batch run logs. This include is the **portfolio-wide contract**. Version-controlled source: `priv/includes/harness-workflow.md` in the harness repo; install to `~/.claude/includes/harness-workflow.md` via `mix harness.install_includes`.

### Relationship to Other Includes (Layered — No Supersession)

| Include | Role relative to harness-workflow |
|---|---|
| `workflow-philosophy.md` | **Foundation.** Evaluator separation, session-per-phase, verification-before-completion. Harness automates the loop while preserving these principles — the **reviewer AI** is the grader, never the implementer's self-report. |
| `task-prioritization.md` | **Task selection.** D/B/U scoring, `rmap next`, parallel markers, refine-don't-duplicate. Harness executes whatever rmap returns; it does not replace prioritization. |
| `worktree-workflow.md` | **Manual parallel sessions.** For hand-build work outside harness dispatch — operator-created worktrees, PR flow, post-merge audit. Harness manages its own per-run worktrees (`harness/<run-id>`); manual worktree rules still apply for hand-build sessions. |
| `dev-lifecycle.md` | **Manual five-phase chain** (`task-driver → worktree → bots → merge → audit-review`). Use when *not* driving through harness. Harness is the automated alternative for dispatchable roadmap tasks; dev-lifecycle still governs plan-and-file, pre-commit review, and post-merge audit. |
| `agent-dispatch.md` / cloud-delegation stack | **Linear/Codex/Cursor PR delegation** without a running harness BEAM. Orthogonal path — projects can use cloud delegation *or* harness; harness subsumes the dispatch+review loop when the OTP node is running. |
| `skills/harness-driver/SKILL.md` (harness repo) | **API surface contract** — MCP tools, `project_eval` patterns, `%LogRecord{}` fields, sharp edges. Load on demand when driving harness; this include covers *workflow*, the skill covers *surfaces*. |

**Adopt per repo:** `@~/.claude/includes/harness-workflow.md` in the project's `CLAUDE.md` (load-on-demand row — not eager; same pattern as `workflow-philosophy.md`).

### The Loop

```
rmap task → implementer AI (worktree) → commit harness/<run-id> → reviewer AI (THE GATE) → done | failed
                                                                              ↓ (done + auto policy)
                                                              MERGE (lander: rebase + ff-push, no re-verify)
                                                                              ↓
                                                              AUDIT (post-merge audit agent, best-effort)
```

One run = one supervised `Harness.Run` gen_statem: fork worktree off target `HEAD`, dispatch implementer, commit diff to `harness/<run-id>`, dispatch cross-family reviewer into the same worktree. The reviewer runs the project's `check_command` hint, fixes what it can, writes `.harness/review.json`. **Success = reviewer `approve`** — never implementer exit code or self-report. There is **no mechanical verification gate** in harness; judgment lives in agents.

Rejections put the task back in the queue for re-dispatch. Fix-and-approve is the near-absolute default for the reviewer.

### When to Dispatch vs Hand-Build

**Default: dispatch every pending rmap task whose dependencies are satisfied.** Hand-build only what harness cannot yet do:

- Scaffolding that reshapes harness runtime (supervision tree, dep stack, Endpoint) **while the run lifecycle itself is in flux**
- Tiny tasks — ALL of (a) D≤2, (b) ≤30 LOC across ≤3 files, (c) no harness-surface change
- UI / LiveView / heex / CSS — headless agents idle-timeout without visual reward; use tidewave + browser
- A harness gap — file via `rmap new`, fix harness, re-dispatch; do not work around by hand-building

### Running a Task

**Prerequisites:** long-lived harness BEAM (`iex -S mix` in the harness checkout), target project registered in `Harness.ProjectRegistry`, clean `git status` on the target's dispatch branch (runs fork worktrees off `HEAD`).

**Three dispatch paths** (prefer top to bottom):

1. **Native MCP — default.** `dispatch-task` (fire-and-forget) or `dispatch-await` (blocks until settle) against `http://localhost:4018/harness/mcp`. Observe via `dispatch-status`, `dispatch-transcript`, `dispatch-verdict_detail`. `scrub_anthropic_key: true` (default) forces subscription OAuth over inherited `ANTHROPIC_API_KEY`.
2. **Tidewave `project_eval` — escape hatch.** Struct-level control the flat tools don't expose (`retry_policy`, fail-over adapter lists, `subscriber: self()`). Run persists to `Harness.ResultStore` even when the eval process exits.
3. **`mix run` driver script — fallback.** Full transcript + reviewer report to terminal. See harness repo `docs/dogfooding-workflow.md` for the canonical template.

> **Never start a second driver BEAM while runs are in flight.** Boot-time worktree sweeps can prune live sibling worktrees. Drive all parallel batches from one long-lived node.

**In-flight idempotency (Task 286):** a second `dispatch-task` / `dispatch-bundle` of the same `{project, task_id}` while a non-terminal run exists returns the **existing** `run_id` (Oban `conflict?: true`), not a duplicate — a retried dispatch is safe and free.

**Write-set serialization (Task 292):** `dispatch-bundle` and cron ready-set dispatch compute each task's `touches ∪ files_to_modify` before enqueue. Tasks with overlapping write-sets are logged and serialized into later waves instead of fanned out together. Callers no longer hand-dedupe ready sets; they must keep `touches` / `files_to_modify` accurate because harness does not infer paths from task prose.

**Renderable vs executable:** `rmap delegate --to` renders native prompts for all six harness adapters (`claude`, `codex`, `cursor`, `grok`, `antigravity`, `pi`). `droid` renders but has no harness adapter — rejected at ingest. All six shipped adapters declare `worktree_isolation: true`.

### Routing & Model Management

- **Resolve `assignee` + `model` from facts, not by reading code.** `routing-brief` is the thin task-writer index: dispatchable agent roster, each agent's standing model (`Config.agent_model/1`), model availability/blocks, and per-agent KPI rollups — every metric carries `n`, no ranking. A model-capable agent with no configured model shows `model: nil, model_required: true`.
- **Scout routing (advisory).** `dispatch-recommend` returns the cross-family scout AI's per-facet `:exploit` pick (with rationale) or a safe `:explore` / `:fallback_no_data` when a facet is unmeasured; `dispatch-assess_facets` forces a fresh scout assessment. The caller decides whether to dispatch the pick — legacy composite scores are not used for routing.
- **Model is required, never defaulted.** Implementer precedence: **task `model` → `{:agent_model, agent}` → REJECT** (`{:model_required, agent}`) — harness never falls through to the CLI's ambient default. The **reviewer has no task-pin axis**: its model comes solely from `{:agent_model, agent}` for the reviewer adapter's agent (`Run.reviewer_model/1`), and a model-capable reviewer with no configured model is rejected *before* the reviewer spawns. `antigravity` (no `--model` flag) is the lone model-incapable exemption.
- **Block exhausted premium models.** A monthly budget can exhaust (e.g. cursor-Opus) while harness still lists the pair as available and routes to it. `model_availability-block_model` (with a `blocked_until` window) removes the pair from routing/cron; `model_availability-unblock_model` clears it.
- **Cost-aware A/B.** `dispatch-compare` runs one task across N adapters (optional per-adapter model overrides) and returns per-adapter `verdict` / `reviewer_diff_size` / `duration_ms` / `token_usage` for selection.

### Reading the Verdict

| `state` / `reason` | Meaning | Action |
|---|---|---|
| `:done` / `:approved` | Reviewer AI approved (possibly after inline fixes — check `reviewer_diff_size`). | Deliverable on `harness/<run-id>`. Review diff, integrate (or let auto-lander handle it), `rmap status <id> done`. |
| `:failed` / `{:review_rejected, report}` | Reviewer rejected (degenerate — near-never by design). | Read `report`. Task back in queue; re-dispatch. |
| `:failed` / `{:review_stuck, report}` | No verdict: reviewer unavailable, crashed, or missing/malformed `.harness/review.json`. | Read `report`. Fix environment or re-dispatch. |
| `:failed` / `{:worktree_failed,_}` `{:agent_spawn_failed,_}` `{:driver_crashed,_}` `{:commit_failed,_}` | Harness-side mechanical failure. | **Harness bug.** File via `rmap new`. |
| `:failed` / `{:checkout_polluted, status}` | Agent wrote outside the run worktree into the main checkout — surfaces as `:failed` **only after bounded AI recovery was exhausted** (see "Self-healing recovery" below). | Recovery declared the run dead. Likely an agent/adapter isolation issue; re-dispatch with a worktree-honoring adapter. |
| `:failed` / `{:checkout_pollution_check_failed, _}` | Post-run pollution `git status` errored. | Rare; transient git/IO. Re-run; inspect checkout if persistent. |
| `:failed` / `:timed_out` | Lifetime budget elapsed. | Raise `:lifetime_timeout` or investigate hang. |
| run process **crashed** (no settle) | gen_statem died. | **Harness bug.** File via `rmap new`. |

Failed runs retain the worktree at `result.worktree_path` for inspection. Approved runs keep branch `harness/<run-id>` after worktree teardown. Use `dispatch-verdict_detail` for the reviewer report, ratings, checks, concerns, warning flag, and `reviewer_diff_size` — no harness-run mechanical per-check stdout.

**The verdict artifact** `.harness/review.json` is `{verdict, report, checks, concerns, facets, skills, ratings}`: `verdict` (`approve`/`reject`) is the gate; `report` is the reviewer's prose; `checks` is the reviewer-written record of commands run and their pass/fail claim; `concerns` is the reviewer's self-flagged caveat list; **`facets`** (open-vocabulary routing KEY — the kind of task) and **`skills`** (v0_13 two-axis rubric, routing VALUE) feed per-facet capability routing; `ratings` is the legacy flat-score fallback. Approved runs with non-empty concerns or a reviewer-authored failed check surface a warning fact; harness never auto-blocks or classifies prose. The artifact lives under `.harness/` (excluded from staging) so it never rides in the deliverable commit.

**Self-healing recovery (the `:recovering` state).** Before settling `:failed` for an *interpretive* non-rejection failure — checkout pollution is currently the one wired call-site — the run spawns a **bounded cross-family recovery AI** (`:recovering` state, budget 1/run) with minimal context (the error term + the main checkout's `git status` + the implementer transcript tail + the failing-check output, never the full transcript). It writes `.harness/recovery.json` `{outcome: "repaired"|"dead", report, repaired}`; harness reads it mechanically and **decides nothing itself**: `repaired` resumes at `:committing` and **re-runs the reviewer gate** (never skips to `:done`); `dead` / missing / malformed settles `:failed` with the original reason. A genuine `verdict: reject` is never routed through recovery. The `Result` carries `recovery_attempts` / `recovery_outcome` / `recovery_repaired` / `recovery_token_usage`. (Tier-1 mechanical self-heal precedes it: the reviewer is re-prompted once on a missing/malformed `review.json` — `reviewer_reprompt_count`, capped at 1 — and rotates to the next cross-family candidate on a reviewer timeout — `reviewer_rotation_count`.)

### 🚨 Recover, Don't Redo — Never Burn Tokens Re-Implementing Committed Work

**A run that committed to `harness/<run-id>` already paid for the implementer. Recovering that branch costs a fraction of a fresh dispatch — re-dispatching from `pending` throws the work away and makes the agent redo all of it.** The reflex to "reset → pending → dispatch again" is a token bonfire whenever a retained branch with commits exists. Check for the branch *first*; pick the cheapest primitive that fits:

| Run state — committed `harness/<run-id>` branch exists | Recover with | Agent tokens |
|---|---|---|
| Approved but unlanded (land-cap, lander crash) | `dispatch-reland` | **zero** — pure git rebase + push |
| Committed, review-stage failure (work is good) | `dispatch-rereview` | zero implementer — re-enters at the reviewer gate |
| Committed, implement-stage incomplete/`:failed` | `dispatch-resume_failed` (`escalate: true` to re-route agent) | **re-spends implementer tokens** — a fresh implementer invocation branched off the retained commits with the failure report injected (contrast `rereview`, which re-runs only the reviewer) |
| Live `:held` run (paused, not dead) | `dispatch-resume` | none — un-pauses in place |
| **No commits / no retained branch** | reset → `pending` + fresh `dispatch-task` | full redo — **the only case where this is correct** |

**Live-run intervention (not recovery of a dead run):** `dispatch-hold` (optionally `interrupt: true`) parks a live run mid-turn, `dispatch-steer` stashes guidance applied on resume, `dispatch-resume` un-pauses in place, `dispatch-cancel` kills it (idempotent). Use hold → steer → resume to force-hand a grinding implementer to the reviewer gate instead of burning the lifetime budget.

**The gate before any reset-to-pending + re-dispatch:** `git branch -a | grep harness/<run-id>` and `git log --oneline origin/<target>..harness/<run-id>`. Commits present ⇒ recover, never redo.

**🚨 First, confirm the run actually *didn't* land — check `origin`, not your local checkout.** Under `landing_policy: :auto` the lander pushes to `origin/<target>` and **deliberately never touches your local checkout** (it ff-pushes from a detached worktree). So after an autonomous land your local `tasks.toml` is **stale**: it still reads `in_progress` for a task the lander already marked `done --shipped-in` on origin. **Reading that stale local status as "the run didn't land" is the trap** — it triggers a wasteful reset-to-`pending` + re-dispatch that *duplicate-lands already-shipped work*. Before concluding anything from task status, `git fetch origin <target> && git rebase origin/<target>` (the existing "Sync development before committing" rule) or read ground truth directly:
- `git log --oneline origin/<target>` — does it already show `task <id> -> done (shipped …)` and the agent-delivery commit? Then it **landed**; your local view was just behind. Do nothing but rebase.
- `dispatch-status <run-id>` / `result_store-list_run_records run_id:<id>` — a record with `state: done, verdict: approve` means the run succeeded; cross-check landing against origin before touching the roadmap.

> **Observed 2026-06-12 (the cautionary tale this section exists for):** three approved runs (246/249/251) landed cleanly to `origin/development` — `done --shipped-in`, audited. But the operator's local checkout hadn't rebased, so `rmap show` read stale `in_progress`. That was misread as "approved but didn't land," the tasks were reset to `pending` and re-dispatched, and task 246 **landed a second time** (duplicate delivery) before the mistake surfaced. Root cause: reading stale local state instead of rebasing on `origin` first. The lander was working perfectly the whole time.

The recovery primitives (`reland`/`rereview`/`resume_failed`) read the persisted `ResultStore` record, which **survives** worktree teardown and node restarts — so a genuinely approved-but-unlanded run (lander hit its land-cap, or a real rebase conflict retained the branch) is recoverable token-free via `dispatch-reland`. Reserve reset-to-`pending` for runs with **no committed branch and no settled record** — and only after confirming against `origin` that the work isn't already shipped.

### Parallel Dispatch

`Harness.Run.Supervisor` is a `DynamicSupervisor` — N crash-isolated runs, each with its own worktree.

- **Batch by dependency graph, then write-set.** Every pending task whose `depends_on` is satisfied can enter the ready set, but harness dispatches only the first wave whose `touches ∪ files_to_modify` are disjoint. Overlapping tasks wait for a later wave after the landed base moves forward.
- **Keep write-set fields accurate.** The dispatcher counts declared path intersections; it does not infer paths from the task body. If two tasks really edit the same function, either let write-set serialization sequence them or fold the coupled work into one rmap task (`task-prioritization.md` § "Refine, Don't Duplicate").
- **One driver BEAM** for all concurrent runs in a wave.
- **Integration order (manual landing):** smallest/isolated diffs onto target first; rebase siblings; run the project's check command on target after last merge.
- **While a wave is in flight:** do not run `rmap status` / `rmap mark` / `rmap new` in parallel sessions against the same checkout — triggers `:checkout_polluted` false-positive.

### Autonomous Landing

Projects with `landing_policy: :auto` and `target_branch`:

1. Approved run enqueues one job on serialized `landing_<name>` Oban queue (limit 1)
2. `Harness.Lander.land/1` rebases `harness/<run-id>` onto `origin/<target>` in a detached worktree
3. **ff-pushes without re-verification** — the reviewer already gated the work
4. Successful push enqueues post-merge audit; advances rmap (`done --verified --shipped-in <sha>`)

Conflict / push-rejected retains the branch for repair — never lands red. Witness notification (read-only sink) alerts the operator; it is **not** a merge gate.

**🚨 Settle ≠ landed — don't conflate the two signals.** `dispatch-await` / `dispatch-await_runs` block until **reviewer settle** (`state: :done, verdict: approve`, or `:failed`), which fires the *moment the reviewer approves* — **before** the serialized `landing_<name>` job rebases and ff-pushes. So an `approve` from `await_runs` means "approved and *queued* to land," **not** "on `origin/<target>`." There is **no blocking await-landed tool**; landing is async and surfaces via the witness sink (`Harness.Notification.FileSink` tailing `~/.harness/settled.jsonl`, or `CommandSink`). To gate a next wave on the base actually moving forward, await settle **then** confirm the land against origin once (`git fetch origin <target> && git log --oneline origin/<target>` for the `task <id> -> done (shipped …)` commit) or consume the witness event — never treat approval as landed. This is the same root cause as the duplicate-land trap above, seen from the dispatch side: a poll loop watching `origin` for the landing commit is a workaround for a *fixed* `await_runs`, not a substitute for it — await settles, origin confirms the land.

**Cron manual-approval mode.** A per-project cron poller in `:auto` mode dispatches unattended; in `:manual` mode it **parks** each dispatch decision instead of enqueuing — drain the parked decisions with `dispatch-pending` and approve them with `dispatch-approve`, keeping the orchestrator in the loop for autonomous polling.

### Orchestrator Loop — the Architect Seat the Per-Task Reviewer Can't Fill

The sections above document the *mechanisms*; this is the **continuous loop** the driving AI runs across waves:

```
plan wave → dispatch → await settle → confirm land on origin → run integration suite on the landed base
          ↑                                                     + review whole surface vs roadmap intent & domain invariants
          └── reconcile rmap ← encode any whole-surface finding as a criterion/test ←┘
```

Each arrow reuses an existing mechanism — don't restate them here: *await settle* (§ "Settle ≠ landed"), *confirm land on origin* (§ "Recover, Don't Redo" → the duplicate-land trap), *reconcile rmap* (the lander already advanced `done --shipped-in` under auto-land — verify, don't double-write), *next wave* (§ "Parallel Dispatch" + write-set serialization).

**🚨 Three review seats, each blind where the next sees — the orchestrator seat is mandatory, not optional.** The per-task reviewer gates *one diff against one task* and is **structurally blind** to two defect classes that land clean through it (worked evidence: delta_calc tasks 24/25/26, see its `## Review Blind Spots` / `## Domain Invariants`):

| Seat | What it sees | What it CANNOT see |
|---|---|---|
| **Per-task reviewer** (cross-family, the gate) | one diff vs one task's acceptance criteria + mechanical checks, in an isolated worktree off a base | the whole surface; domain ground truth |
| **Post-merge audit AI** (best-effort) | cold build of the merged commit range; hygiene | whether a domain constant is *wrong*; roadmap-intent fit |
| **Orchestrator** (the architect seat — you) | whole integrated surface vs roadmap intent + domain invariants across all landed waves | — (this is the seat of last resort) |

The two blind classes, both real-correctness, both passing every per-task check:

- **Domain ground truth** — a wrong venue constant (`@funding_periods_per_day 3`, overstating Deribit's hourly funding ~8×) is internally consistent and fully tested *because the golden was computed with the same wrong constant* — coverage ratifies the bug. The reviewer has no signal; that knowledge lives in the architect's head.
- **Cross-module global invariants** — write-set-disjoint parallel dispatch means two worktrees can each define `project_payback_timeline` and neither review sees the other; the collision only exists once both have landed on the integrated base. Only a whole-surface seat catches it.

**🚨 Run the integration suite on the landed base — this is NOT redundant with per-task review.** After each wave lands, run the project's full check (`mix ci` / `mix precommit.full`) on the freshly-landed `origin/<target>`. The per-task reviewer ran its checks in an *isolated worktree off an earlier base, before sibling waves landed* — cross-module breakage doesn't exist until multiple landed diffs coexist. This generalizes the manual-landing-only "run the project's check command on target after last merge" (§ "Parallel Dispatch") into a standing per-wave step.

**Two framing guards — keep this consistent with the harness mantra:**

- **It's an agent seat, not harness code.** The mantra ("count facts in code; judge with an AI") forbids *harness* computing meaning — it does **not** forbid the orchestrator AI from reviewing the whole surface or running the suite. This adds no mechanical gate to harness; it's judgment in an agent, which is exactly where judgment belongs.
- **The output crystallizes into encoded invariants — don't leave it a manual sweep.** When the architect seat catches a whole-surface or domain defect, the highest-value move is not the manual catch — it's pushing the rule into an **acceptance criterion or a manifest-wide CI test** (the delta_calc rule) so the per-task gate absorbs that class going forward. Orchestrator review *feeds* the criteria/CI; it must not become a permanent re-review of every diff. A finding caught twice by hand is a missing test.

### Portfolio Conventions

- **Agent does not commit unless asked.** Staged-but-uncommitted is the default handoff between implementer and reviewer sessions (`workflow-philosophy.md` § "Implementer / Reviewer Handoff"). Harness runs commit agent work to `harness/<run-id>` automatically — that is harness's deliverable branch, not the operator's main checkout.
- **Witness notification is sakshi (read-only).** Landing outcomes notify via configured command sink; the sink grants no merge capability. Human operator reviews blocked/conflict outcomes — harness does not silently force-push past conflicts.
- **`check_command` is a hint to the reviewer.** Free text (e.g. `"mix precommit.full"`) — the reviewer runs and judges it; harness does not execute it mechanically.
- **The cross-family reviewer reads `AGENTS.md`, not your Claude skills/includes.** `AGENTS.md` is generated from `CLAUDE.md` by `claude-marketplace/scripts/sync-agents-md.sh`, which recursively inlines every `@`-import. **Regenerate it after any `CLAUDE.md` change** (`bash ~/_DATA/code/claude-marketplace/scripts/sync-agents-md.sh`, or `--dry-run` to preview) so the reviewer gates against current rules — a stale `AGENTS.md` makes codex/cursor/grok judge against rules you've already changed. **`--check` is the freshness gate** — it re-renders in memory and exits non-zero if `AGENTS.md` has drifted (diffs rendered output, not mtimes, so it catches drift in transitive `@`-imports too); wire it into CI / a pre-commit hook / the `check_command` so staleness fails loudly instead of silently. Consequence under Opus-4.8 skill-on-demand: once `CLAUDE.md` slims to the eager floor, reviewer-critical facts that *were* carried by eager includes (the `check_command` gate; that `mix test.json` / `mix dialyzer.json` emit JSON **by design** — parse for real failures, never flag the envelope; plain `mix dialyzer` is authoritative when the JSON encoder can't serialize a warning) no longer reach `AGENTS.md` via those imports. Put them in a **self-contained `## Toolchain & check commands` section in `CLAUDE.md`** so they survive the slim-down and flow into `AGENTS.md` on regen (ref: `tapakly/CLAUDE.md`, `ccxt_extract/CLAUDE.md`).
- **Delegation roster — opus last, and don't over-default to codex.** When assigning a dispatchable task to a harness adapter, prefer the external agents — **cursor, codex, grok** — and reserve the **claude/opus** adapter for work that genuinely needs it (harness-surface changes, judgment-heavy review, tasks the cheaper adapters keep bouncing). Opus tokens are precious: spend them last, not by default. Mix adapters across a wave for review coverage. A repo may override the roster in its own CLAUDE.md.
  - **Observed failure mode: reflex-routing everything to `codex`.** Run ledgers skew heavily codex-over-cursor/grok. Actively spread `assignee` across all three; reserve codex for tasks it's genuinely scored best on, not as the default.
  - **`cursor` runs on Composer (`composer-2.5`) by default — and that's the data-backed pick.** Pin `model = "composer-2.5"` for cursor work: it's the cheapest cost-to-green in the ledger, and **every cursor capability KPI is measured on Composer** (it's a multi-model front-end, but the scores you'd route on reflect Composer, not whatever you pin). The `composer-2.5-fast` variant is cheaper still, but its budget routinely exhausts and the operator blocks it — so **`composer-2.5` (non-fast) is the standing default**; confirm the live id with `cursor-agent --list-models` / `model_availability-list_available_models cursor`. A heavier cursor model exists (`cursor-agent --list-models` lists `claude-opus-4-8-thinking-high` etc.) but is **not** the default, carries **no** capability data, and draws a *monthly Opus token budget that exhausts* (when spent the operator blocks it and routes Opus-grade work to codex/gpt-5.5) — pinning it *claims performance the ledger doesn't show*, so reach for it only with a concrete, named reason, not as the "design-heavy/Opus-grade" reflex. Model IDs churn; confirm with `cursor-agent --list-models`. **`model` is REQUIRED at creation for any non-`human` assignee** (`rmap new` rejects a model-less dispatchable task — "a dispatchable task must pin the LLM it runs on"; see `rmap.md` § "Pinning an LLM model"); "leave `model` unset for the agent default" does NOT work. Set `assignee` **and** `model` at task creation per `rmap.md`.

### Known Sharp Edges

- **Fresh worktrees lack `deps/` / `_build/`.** Implementer and reviewer each run project bootstrap (e.g. `mix deps.get`) when needed — budget timeouts for cold worktrees.
- **Reviewer runs the checks.** No mechanical check stack. Correct-but-not-pristine work → reviewer fixes and approves (`reviewer_diff_size` > 0).
- **Cold dialyzer PLT** dominates first reviewer check run in Elixir worktrees.
- **Nested Claude auth.** `ANTHROPIC_API_KEY` shadows subscription OAuth — scrub per run (`scrub_anthropic_key: true` or `env: %{"ANTHROPIC_API_KEY" => false}`).
- **Parallel-session rmap mutations** during a run can false-positive `:checkout_polluted` — wait for the wave or use a separate worktree.

### Repo-Specific Detail

| Need | Where |
|---|---|
| Harness API surfaces, MCP tool shapes | `skills/harness-driver/SKILL.md` in harness repo |
| Driver script template, cutover history, run log | `docs/dogfooding-workflow.md` in harness repo |
| Agent-gate architecture spec | `docs/agent-gate-workflow.md` in harness repo |
| Cross-checkout consumer setup | `skills/harness-driver/SKILL.md` § "Context A" |
| D/B/U scoring, task writing | `task-prioritization.md`, `task-writing.md` |
| Manual session/PR/audit chain | `dev-lifecycle.md`, `worktree-workflow.md` |


> **Trimmed 2026-05-30; re-aligned 2026-06-22.** The original `@`-imported 14 includes + the 43 KB harness-driver SKILL (~44k tokens always-on), which drove compulsive re-reading on Opus 4.8. The eager floor is now the two above — `critical-rules` (guardrails, ambient by necessity) + `harness-workflow` (the implement→review→land loop + delegation roster, load-bearing every session in this dogfooding repo — the setup-guide's "second eager include for harness-registered repos"). `code-style` (KPIs) and `rmap` (roadmap decision layer) are now **load-on-demand skills** (`elixir:code-style` / `tasks:rmap`) — Opus 4.8 self-invokes them when the action calls for it. `response-conventions` is inherited from `~/.claude/CLAUDE.md`, not re-imported here. Everything else is **load-on-demand** — pull it only when the trigger matches.

## Load-on-demand (don't auto-load — read the file or invoke the skill when the trigger hits)

| When you need… | Load |
|---|---|
| `mix test.json` flags / jq recipes | Skill `elixir:ex-unit-json` |
| `mix dialyzer.json` flags / fix_hints | Skill `elixir:dialyzer-json` |
| `mix` / `ex_dna` / `ex_ast` command surface | Skill `elixir:development-commands` |
| Complexity KPIs / per-tier code budgets (functions·lines·depth) | Skill `elixir:code-style` |
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
| Before PR / handoff | `mix precommit.full` (alias `mix ci`) — `precommit` + `ex_dna --max-clones 0` (zero-tolerance clone gate) + `reach.check --arch --smells` (architecture policy in `.reach.exs`) + `dialyzer.json`. No `.github/workflows` yet — this alias **is** the mergeable bar. |
| Ecosystem entry point | `mix ci` — vibe_kit-convention name; delegates to `precommit.full` (one gate, not two). |
| Sync harness skills | `scripts/sync-harness-skills.sh` (`--dry-run` to preview) — after editing `priv/includes/harness-workflow.md` or `skills/harness-driver/SKILL.md`, propagate to `~/.claude/includes/` + the marketplace `harness` plugin skills. The general marketplace sync excludes these two. |
| Regenerate AGENTS.md | `bash ~/_DATA/code/claude-marketplace/scripts/sync-agents-md.sh` (`--check` = freshness gate, exits non-zero on drift) — after any `CLAUDE.md` edit, so cross-family reviewers gate against current rules. **Never hand-edit `AGENTS.md`.** Operator/marketplace gate (path is the personal checkout) — not wired into `precommit.full`. |

**Per-edit hooks already run this stack** (`format`, `compile`, `test.json`, `credo`, `dialyzer.json`, `sobelow`, `doctor`) on every touched file — don't re-run a check the hook just graded. Full-suite `precommit.full` earns its cost only before a PR/merge, after `mix deps.get`, or on a branch switch (see global CLAUDE.md § "Don't Re-Run Hook-Driven Checks").

## Toolchain & check commands

Self-contained so it reaches `AGENTS.md` (and the cross-family reviewer) even after the eager floor slimmed `code-style`/`rmap` to skills.

- **The canonical gate is `mix precommit.full` (alias `mix ci`).** It bundles `format --check-formatted`, `compile --warnings-as-errors`, `credo --strict` (with the `ExSlop` AI-slop plugin), `doctor`, `test.json --cover --cover-threshold 80`, `sobelow`, `ex_dna --max-clones 0`, `reach.check --arch --smells`, and `dialyzer.json`. There is no `.github/workflows` — this alias is the mergeable bar. `check.fast` / `precommit` are the faster inner loops; dialyzer + clone + reach gates live only in `precommit.full` (cold-PLT / heavier-pass cost).
- **`mix test.json` and `mix dialyzer.json` emit JSON by design** (ex_unit_json / dialyzer_json reporters). Parse the payload for *real* failures — never flag the JSON envelope itself as an error. When the dialyzer_json encoder can't serialize a particular warning, **plain `mix dialyzer` is authoritative** for that warning.
- **`ex_dna --max-clones 0`** is a zero-tolerance AST-clone gate; **`reach.check --arch --smells`** validates the architecture policy in `.reach.exs` (forbidden cross-boundary calls + the `boundaries[:public]` facade list) plus the smell surface. A red here is real debt to fix or model honestly in `.reach.exs`, not to suppress.
- **`AGENTS.md` is generated from `CLAUDE.md`** by `~/_DATA/code/claude-marketplace/scripts/sync-agents-md.sh` (recursively inlines every `@`-import; `--check` re-renders and exits non-zero on drift). Regenerate after any `CLAUDE.md` change so the reviewer gates against current rules — **never hand-edit `AGENTS.md`**.

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
- **Agent vs model — pin the model per run.** Each adapter threads `Invocation.model` → its CLI's `--model` flag (`AgentAdapter.model_args/1`), so the *agent* (`assignee`) and the *model that agent runs* (`model`) are orthogonal. This is most load-bearing for **Cursor: it is a multi-model front-end, not "the Composer agent."** Beyond its in-house `composer-*` default, `cursor-agent` fronts Opus-tier (Opus 4.8 1M), Sonnet, GPT, Gemini, Grok, and Kimi models — so a `cursor` dispatch pinned to an Opus 4.8 model id is a full Opus-tier implementer/reviewer — **route Opus-grade tasks to cursor, not just to claude.** Pin it on the rmap task (`model = "<id>"`); with no task pin, the operator-set per-agent default fills in (`Config.agent_model/1` ← the `{:agent_model, agent}` "Agent models" settings card), and an unset default is **rejected, never silently run on the agent's CLI default** — a model-capable adapter that resolves to no model fails the dispatch with `{:model_required, agent}` (`AgentAdapter.invoke/2` + the dispatch/reviewer fail-fasts; the guard against a sticky premium CLI default burning the budget on every later run). So the implementer precedence is **task `model` → `{:agent_model, agent}` → REJECT**; the **reviewer** has no task-pin axis, so its model comes *solely* from `{:agent_model, agent}` for the selected reviewer adapter's agent (`Run.reviewer_model/1`, Task 256 — a model-capable reviewer with no configured model → `{:model_required}`, rejected before the reviewer Port spawns). **Antigravity** joined the model-capable set in `agy` 1.0.10 (`--model` + `agy models`, families gemini/claude/gpt-oss); harness validates pins against its catalog because `agy --model` silently falls back on unknown ids. Model IDs churn — never trust a hardcoded roster; read the live per-agent catalog from the node (`model_availability-list_available_models`, `model_availability-refresh_catalog` to re-poll the CLIs, `model_availability-list_blocks` for what's blocked). For the live routing picture (per-agent load, success/first-pass rates, per-domain capability ratings, which premium models are blocked) read it from the running node — `result_store-aggregate_by_agent` + `agents-list` + `model_availability-list_blocks` — never a count hardcoded here.
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
