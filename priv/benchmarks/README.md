# Capability benchmark corpus (Elixir stack)

Fixed, versioned eval items under `*.toml` — loaded by `Harness.Benchmark.Corpus`.
Roadmap tasks are consumed; these items stay stable for cross-agent comparison.

## Domain coverage

| Domain | Items | What they probe |
| --- | --- | --- |
| **OTP / gen_statem** | `bench.otp.latch`, `bench.otp.supervised_counter` | Explicit `gen_statem` event handling vs supervisor wiring + a child GenServer — process design and OTP supervision without Phoenix/UI noise. |
| **GenServer** | `bench.genserver.accumulator` | Call/cast protocol, named registration, and stateful accumulation — the baseline OTP server pattern agents still get wrong in isolation. |
| **LiveView / Phoenix** | `bench.liveview.tally`, `bench.liveview.form_validate` | `handle_event` + assign updates vs form/change tracking — UI state on the BEAM, not controller-only MVC. |
| **Oban** | `bench.oban.reverse`, `bench.oban.attempt_echo` | `Oban.Worker` perform contract and attempt-aware return values — background job semantics harness itself depends on. |
| **Ecto** | `bench.ecto.embedded_profile`, `bench.ecto.changeset_normalize` | Embedded schemas + changesets without leaning on repo migrations — data-shape validation at the boundary. |
| **Plain Elixir** | `bench.elixir.tree_walk`, `bench.elixir.pipeline` | Pure recursion/traversal and `with` pipelines — language fluency without OTP/DB/UI scaffolding. |

## Gradeability

Each item targets the `harness` project and the `:elixir` check stack (format/compile are not in that stack;
reference implementations are verified by the matching `test/harness/benchmark/eval/*_test.exs` suite and
the corpus content tests).

Reference implementations live in `lib/harness/benchmark/eval/` with tests in
`test/harness/benchmark/eval/`. They prove the spec is satisfiable under the project's mix toolchain.
Task 122 dispatch will use a baseline snapshot without those modules so agents run the empty-then-green path.

## Sizing

Every item is scoped for one harness dispatch: one or two modules, focused tests, no multi-file refactors.
