# Known Bugs

Running log of confirmed defects. Newest first. Promote to `rmap new` tasks when fixing.

---

## 3. `dispatch-register_project` is uncallable over MCP — `nonempty_list(...)` in the `@spec` yields a typeless `languages` schema, so JSON clients stringify the array

- **Severity:** moderate (the tool is advertised but provably uncallable from a standard MCP client with the documented argument; an orchestrator registering a project must drop to raw JSON-RPC or `project_eval`. Reproducible, 100%.)
- **Surface:** descripex `@spec`→JSON-Schema derivation, consumed by `Harness.Manifest`/`Harness.Chat.Tools`; validation lands in `Harness.ProjectRegistry.validate_languages/1` (`lib/harness/project_registry.ex:508-509`).
- **Discovered:** 2026-08-20, registering `zen_websocket` from a Claude Code session in that repo. Origin: zen_websocket.

### Repro

Both attempts via the `mcp__harness__dispatch-register_project` tool:

| Argument sent | Error returned |
|---|---|
| `languages: ["elixir"]` (JSON array) | `["error",["invalid_project",["invalid_languages","[\"elixir\"]"]]]` |
| `languages: "elixir"` (bare string) | `["error",["invalid_project",["invalid_languages","elixir"]]]` |

In the first case the array arrived at `validate_languages/1` as the literal **string** `["elixir"]`, so it fell through the `[_|_]` clause to `validate_languages(other)`. Registration only succeeded via a hand-rolled `tools/call` against `http://localhost:4018/harness/mcp` carrying a real JSON array — which returned `["ok",{"name":"zen_websocket"}]`.

### Root cause (two layers, neither in harness)

`register_project/8` carries a usable `@spec` (`lib/harness/dispatch.ex:940-950`) and descripex's spec-derived enrichment does fire — but only for one of its two list params:

| Param | `@spec` type | Emitted JSON Schema |
|---|---|---|
| `warm_paths` | `[String.t()]` | `{"type": "array", "items": {"type": "string"}}` |
| `languages` | `nonempty_list(atom() \| String.t())` | `{"description": "..."}` — **no `type`** |

Probed directly against `JSONSpec.convert/1` in the descripex checkout (2026-08-20):

```
[String.t()]                       -> %{"items" => %{"type" => "string"}, "type" => "array"}
list(String.t())                   -> %{"items" => %{"type" => "string"}, "type" => "array"}
nonempty_list(String.t())          -> ** (ArgumentError)
nonempty_list(atom() | String.t()) -> ** (ArgumentError)
[atom() | String.t()]              -> ** (ArgumentError)
[String.t(), ...]                  -> ** (ArgumentError)
```

1. **`json_spec` (hex `~> 1.1`, dannote — upstream, not ours)** supports only the `[T]` and `list(T)` forms. `nonempty_list(T)`, the `[T, ...]` literal, and **any union element type** raise `ArgumentError`. The union case is the broader miss: `[atom() | String.t()]` fails even though its list form is supported.
2. **descripex** — `safe_convert/1` (`lib/descripex.ex:625`) rescues `ArgumentError` and returns `:skip`, so the param ships **silently typeless**. `:skip` is right for genuinely inexpressible types (tuples, structs); here it hides a type that *is* expressible, with no warning and no manifest-level "N params typeless" signal.

Tracked on the descripex side in `~/_DATA/code/descripex/BUGS.md` #1.

### Why this escaped Task 259's regression net

Task 259 ("Fix the MCP param boundary once and for all", phase 13, done) closed the class and added a Manifest-wide sweep test — but its acceptance criterion reads *"each declared **scalar/atom** param round-trips"*. **List-valued params were never in the sweep**, so a typeless array property still ships. The class is not actually closed.

### Suggested direction (for the eventual `rmap new`)

Two halves, and the first is the durable one:

1. **descripex** (`~/_DATA/code/descripex`): normalize the AST before handing it to `JSONSpec.convert/1` — `normalize_remote_aliases/1` already does exactly this kind of rewrite for `String.t()`. Fold `nonempty_list(T)` / `[T, ...]` down to `[T]`, and reduce union element types to their widest expressible member. That closes the gap without waiting on an upstream `json_spec` release; a PR to dannote/json_spec is the clean complement, not the prerequisite. Separately, make a skipped-but-expressible param visible (warn or expose a count) instead of shipping typeless in silence.
2. **harness**: widen Task 259's sweep test from scalar/atom params to **every** declared param type, so a typeless property on any tool fails the suite. Without this, the next uncovered type form escapes the same way. Optionally also relax `validate_languages/1` to decode a JSON-string-encoded list, as `decode_param/2` already does for objects (belt-and-braces, not the fix).

Cross-check while in there: `warm_paths` proves the typed path works, so this is a mapping gap, not a wiring failure.

---

## 2. Run crashes with `case_clause` on the `{:cancel, {:redispatched, _}}` path instead of settling cleanly — `dispatch-task` initial run dies, auto-redispatch saves it

- **Severity:** moderate (self-healing — the redispatch always produced a healthy replacement that ran to completion — but the first run dies with a `run_crashed` gen_statem crash, burns its worktree setup, and surfaces a scary `:failed`/`run_crashed` verdict that an orchestrator can misread as a real failure. Reproducible.)
- **Surface:** `Harness.Run` gen_statem cancel/redispatch handling — the `{:cancel, {:redispatched, "<new-run-id>"}}` term is not matched by a case clause and raises `case_clause` instead of settling the superseded run gracefully (e.g. as `:superseded`/`:redispatched`).
- **Discovered:** 2026-06-23, orchestrating `ccxt_client` wave-3 dispatches. Origin: ccxt_client.

### Repro (observed twice, both `grok` adapter, same shape)

Both via `dispatch-task project=ccxt_client adapter=grok`:

| Task | Original run (crashed) | `dispatch-status` reason | Redispatched-to (healthy) |
|---|---|---|---|
| 191 | `run-1782214594617-cc707d05` | `["run_crashed",["case_clause",["cancel",["redispatched","run-1782214902101-39a1ad84"]]]]` | `run-1782214902101-39a1ad84` (ran to `done`, landed `6b1717ff0585`) |
| 193 | `run-1782216353982-f8878e33` | `["run_crashed",["case_clause",["cancel",["redispatched","run-1782216961629-008a2c80"]]]]` | `run-1782216961629-008a2c80` (running healthy, fresh worktree) |

So a single `dispatch-task` call results in: original run starts → gets a `{:cancel, {:redispatched, <new>}}` signal → the run gen_statem has no matching clause for that term → `case_clause` → `run_crashed` settle on the original; the redispatched run is fine.

### Open questions for harness triage (findings only — not prescribing the fix)

1. **Why is the original being redispatched/cancelled at all?** A single `dispatch-task` produced two run ids per task. Candidates: a double-enqueue (the dispatch path enqueues, then something — cron ready-set poller? in-flight idempotency conflict resolution? — re-enqueues the same `{project, task}` and cancels the first), or an intentional supersede whose terminal handling is just unimplemented. The in-flight idempotency note says a second dispatch of a non-terminal `{project, task}` should return the *existing* run id (Oban `conflict?: true`), not cancel-and-replace — so if this is idempotency firing, it's taking the wrong branch.
2. **The crash itself is the bug regardless of #1:** the `{:cancel, {:redispatched, _}}` path should settle the superseded run as a clean terminal state (`:superseded`/`:redispatched`), not raise `case_clause`/`run_crashed`. An orchestrator reading `dispatch-status` sees `state: failed, reason: run_crashed` and cannot distinguish this benign supersede from a genuine gen_statem death without pattern-matching the nested reason term.
3. **Whether it's `grok`-specific or adapter-agnostic** is unknown — only observed on grok so far (the only adapter dispatched in this batch); the cancel/redispatch path looks adapter-independent, so suspect it reproduces on any adapter.

### Suggested direction (for the eventual `rmap new`)

Add a clause handling `{:cancel, {:redispatched, new_run_id}}` that settles the superseded run as a non-error terminal state carrying `redispatched_to: new_run_id`, so `dispatch-status` reports it as superseded (not `run_crashed`) and the worktree teardown is clean. Then separately investigate *why* the redispatch fires for a single `dispatch-task` (the double-run-id question).

---

## 1. `dispatch-register_project` MCP description misframes persistence as opt-in (`:repo_enabled` is opt-out, defaults `true`)

- **Severity:** minor (doc/accuracy — no runtime misbehavior, but actively misleads operators/agents into redundant work and false "registration will be lost" conclusions)
- **Surface:** MCP tool description + `Harness.ProjectRegistry` moduledoc
- **Discovered:** 2026-06-23, while registering `quantex` via `mcp__harness_tidewave__project_eval` + `Harness.ProjectRegistry.register/1`.

### What it says

`lib/harness/dispatch.ex:799` (the `dispatch-register_project` MCP tool description):

> "Runtime registration does NOT survive a BEAM restart unless `:repo_enabled` — for durable registration use `config :harness, :projects`."

Echoed in `lib/harness/project_registry.ex:5` and `:63` ("When `:repo_enabled` … survives a BEAM restart via Postgres").

### Why it's wrong (or at least misleading)

`:repo_enabled` is **opt-out, not opt-in** — it **defaults to `true`**:

```elixir
# lib/harness/settings_store.ex:54
if Application.get_env(:harness, :repo_enabled, true) do   # <-- default TRUE
```

So on the harness self-host / default deployment (where `:repo_enabled` is simply unset), the Postgres backend is active and `register/1` **does** persist durably. The phrasing "does NOT survive … unless `:repo_enabled`" reads as if persistence is something you must turn on, when in fact you'd have to explicitly set `repo_enabled: false` to lose it. `config :harness, :projects` is **not** required for durability — it only seeds missing rows on first boot (correctly stated at `project_registry.ex:63`, contradicting the MCP description's "use config for durable registration").

### The trap it sets

An operator/agent checks `Application.get_env(:harness, :repo_enabled)` (no default) → gets `nil` → concludes persistence is off → wrongly plans to add `config :harness, :projects`. The correct read is `Application.get_env(:harness, :repo_enabled, true)`, or just `Harness.ProjectRegistry.Persistence.enabled?()`.

### Evidence (verified against the live node, 2026-06-23)

```elixir
Process.whereis(Harness.Repo)                                   #=> #PID<…> (started)
Application.get_env(:harness, Harness.Repo) |> is_list()        #=> true
Harness.ProjectRegistry.Persistence.enabled?()                  #=> true
Application.get_env(:harness, :repo_enabled)                    #=> nil   (← the misleading read)

# quantex registered at runtime via register/1, then:
Harness.ProjectRegistry.Persistence.list() |> length()          #=> 18 (quantex present in Postgres)
```

### Suggested fix

Reword the three descriptions to state persistence is **on by default** and only disabled by `repo_enabled: false`. E.g. for `dispatch.ex:799`:

> "Registration persists to Postgres by default (`:repo_enabled` defaults to `true`) and survives a BEAM restart. Set `repo_enabled: false` for ephemeral/in-memory registration. `config :harness, :projects` is for seeding rows at boot, not a durability requirement."

Apply the same correction to `project_registry.ex:5`. Optionally have the MCP tool surface `Persistence.enabled?()` rather than naming the raw config key.
