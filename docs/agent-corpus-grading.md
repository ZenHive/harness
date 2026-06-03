# Agent-evaluation corpus — grader isolation (Task 151)

Canonical design + rationale: `~/_DATA/concepts/agent-corpus/README.md`. This
doc records the **harness-side resolution** of that design's open questions and
the registration/run procedure for a corpus project.

## The load-bearing decision: Mode-B grader isolation (Q1 — settled)

A corpus task is graded in one of two modes:

- **Mode A (visible spec / TDD).** The grading test ships in the corpus repo;
  the agent makes it pass. Measures implementation skill on a known surface.
- **Mode B (hidden grader / unfamiliar library).** The grading test must be
  **withheld** from the agent's worktree — if it is present, it reveals the API
  and destroys the measurement (does the agent read the source, or hallucinate?).

**Q1 was: does `Harness.CheckStack`'s `setup` already support a post-agent /
pre-check injection step, or is it a small feature to add?**

**Answer: `setup` is NOT sufficient, and the minimal feature was added.** `setup`
runs in *both* lifecycle phases — `Harness.Verification.prepare/2` (the
worktree-provisioning pass, *before* the agent spawns) and `run/2` (ahead of the
grading checks). A grader copied in via `setup` would therefore land in the
agent's worktree at provision time and reveal the API. Mode B needs a step that
runs **only at verification time**.

That step is the new **`inject`** field on `%Harness.CheckStack{}`:

- `inject` commands run in `Harness.Verification.run/2`, after `setup` and
  before the grading `checks`, in the stack's `workdir`.
- `inject` is **never** run by `prepare/2` — so an injected file never reaches
  the agent's worktree.
- Like `setup`, an `inject` failure is an environment error
  (`{:inject_failed, _}`), not a red verdict.

A Mode-B benchmark withholds its grading test from the corpus repo and lists an
`inject` command that copies the grader in from a host-side answer key right
before checks run:

```elixir
%Harness.CheckStack{
  name: :corpus_elixir,
  # Copied in only at verification time — the agent never had it.
  inject: [
    %Harness.Verification.Check{
      name: "inject-mode-b-grader",
      command: "cp",
      args: ["/abs/answer-key/grade_b.exs", "/abs/worktree/grade_b.exs"]
    }
  ],
  checks: [
    %Harness.Verification.Check{name: "mode-a", command: "elixir", args: ["-r", "lib/counter.ex", "grade_a.exs"]},
    %Harness.Verification.Check{name: "mode-b", command: "elixir", args: ["-r", "lib/vault.ex", "-r", "lib/vault_user.ex", "grade_b.exs"]}
  ]
}
```

Proven deterministically (no live agent) in:

- `test/harness/verification_test.exs` — `describe "run/2 inject (Mode-B hidden
  grader)"`: inject runs at verification time, is withheld from `prepare/2`, and
  an inject failure is an environment error.
- `test/harness/corpus_grading_test.exs` — a corpus-shaped repo with one Mode-A
  and one Mode-B task graded end-to-end: both pass, the hidden grader is absent
  after `prepare/2`, and a *hallucinated* Mode-B solution (assuming the idiomatic
  `{:ok, v}` return instead of reading the vendored lib's `{:found, v}` shape)
  correctly fails the hidden grader.

## The other open questions

- **Q2 — answer-key storage (host dir vs private repo).** Realization **(a)**:
  graders live on the host *outside* the agent's worktree (a `.answer-key/` dir
  in the corpus repo, gitignored, or a sibling answer-key path) and are copied in
  by `inject`. A separate private repo (realization (b)) is the later
  anti-contamination hardening, out of scope here.
- **Q3 — `corpus_version` fingerprint.** `Harness.CapabilityScore.corpus_version/1`
  already derives a deterministic SHA-256 over the corpus items'
  `id:version` pairs — version-comparable and append-mostly by construction
  (adding a task or bumping a task's `version` changes the fingerprint; scores
  are keyed by `(agent, domain, corpus_version)`). Use that over a hand-bumped
  string; the corpus repo's git SHA is a coarser alternative.
- **Q4 — worktree network access vs vendoring.** **Vendor** the unfamiliar
  library into the corpus repo (more reproducible, removes a network variable).
  The Mode-B proof above vendors a small `Vault` lib with a non-idiomatic API.

## Registering a corpus project

A corpus repo is just another `%Harness.Project{}` with `landing_policy: :manual`
(corpus runs are *scored*, never merged) and `review_green: false` — a corpus run
measures the implementer's raw capability, so the cross-family reviewer must
never "fix" its work before scoring. Register it via `config :harness,
:projects` (see `config/dev.exs` for the harness self-registration) or
`Harness.ProjectRegistry.register/1`:

```elixir
Harness.ProjectRegistry.register(%Harness.Project{
  name: "agent-corpus-elixir",
  source: {:local, "/abs/path/to/agent-corpus-elixir"},
  roadmap_path: "/abs/path/to/agent-corpus-elixir",
  landing_policy: :manual,
  review_green: false,
  check_stacks: [
    %Harness.CheckStack{
      name: :corpus_elixir,
      inject: [
        # one cp per Mode-B task, from the host answer key
      ],
      checks: [
        # Mode-A in-repo graders + Mode-B injected graders
      ]
    }
  ]
})
```

## Running the comparison

Once registered, fan one corpus task to N adapters and score:

```elixir
{:ok, item} = Harness.Roadmap.ingest("agent-corpus-elixir", task_id)
{:ok, comparison} =
  Harness.Batch.AgentEvaluation.compare(
    item,
    "agent-corpus-elixir",
    [Harness.AgentAdapter.Claude, Harness.AgentAdapter.Codex]
  )

# Persist per-(agent, domain, corpus_version) capability scores.
corpus_items = Harness.Benchmark.Corpus.list()
{:ok, _scores} =
  Harness.CapabilityScore.score_domain([comparison], corpus_items, :genserver)
```

The scores render in `Harness.Dashboard.CompareLive` (`/harness/compare`). This
live cross-adapter run needs a booted harness node, Postgres, and the real agent
CLIs on `PATH`; it is a host step, not a headless one.
