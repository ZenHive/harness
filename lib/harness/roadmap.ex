defmodule Harness.Roadmap do
  @moduledoc """
  Ingests a task from an rmap roadmap and renders it as an agent prompt.

  This is the input half of the harness loop: the roadmap becomes the job
  queue. `ingest/2` fetches a task — by id or the next pending one — and hands
  back a `Harness.Roadmap.Item` carrying a ready-to-run agent prompt.

  ## Why it shells out to `rmap`

  Ingestion drives the `rmap` CLI rather than parsing `roadmap/tasks.toml` or
  `roadmap/data.json` itself. rmap owns the roadmap schema and the
  pending-selection order (D/B/U efficiency, markers, dependency gating), and
  `rmap delegate` owns the prompt template. Re-implementing any of that in
  harness would duplicate the roadmap and couple harness to rmap's
  `schema_version`. Shelling out keeps rmap the single source of truth.

  The rendered `prompt` is the verbatim output of `rmap delegate` — harness
  passes it through untouched, consistent with its raw-passthrough design.

  ## Usage

      Harness.Roadmap.ingest(:next)
      Harness.Roadmap.ingest({:id, "6"}, project: project)
      Harness.Roadmap.ingest({:id, "6"}, project_root: "/path/to/project")
      Harness.Roadmap.ingest({:id, "6"}, agent: :codex)

  Ingestion is read-only: it never writes the roadmap back (claiming a task is
  the run-lifecycle's concern).

  ## Renderable vs Executable Agents

  rmap's `delegate --to` renders a native prompt for every agent harness ships —
  `:claude`, `:codex`, `:cursor`, `:grok`, `:antigravity`, `:pi`. Any of the six
  is a valid `:agent` for `ingest/2` and runs directly on its own adapter; there
  is no two-step indirection.

  rmap can also render for agents harness has no adapter for (currently `droid`).
  Passing such an agent to `ingest/2` is rejected by design — there is no executor
  to run the rendered prompt. Closing that gap is mechanical and two-sided: a new
  rmap `delegate --to` target is a small rmap-lib task (the rmap binary is ours,
  `../rmap/`), and harness then adds an `AgentAdapter` plus the agent to
  `@valid_agents`. The render side already exists for `droid`; only the harness
  adapter is missing.
  """

  use Descripex, namespace: "/roadmap"

  alias Harness.CapabilityDomain
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Durable
  alias Harness.Roadmap.Item

  # The agents harness can both render (via `rmap delegate --to`) AND execute
  # (has an `AgentAdapter` for). rmap renders natively for all six, so each is
  # accepted here and dispatched directly on its own adapter. An agent rmap can
  # render but harness can't run (e.g. :droid — no adapter yet) is rejected here
  # rather than failing downstream with an opaque `{:rmap_failed, _}` or a
  # missing-module crash. Adding one is two-sided: an rmap-lib `--to` target
  # (already done for droid) plus a harness adapter listed here.
  @valid_agents [:claude, :codex, :cursor, :grok, :antigravity, :pi]

  @typedoc "Which task to ingest: the next pending one, or one named by id."
  @type selector :: :next | {:id, String.t()}

  @typedoc "A reason `ingest/2` can fail with."
  @type error ::
          {:invalid_agent, term()}
          | {:invalid_selector, term()}
          | {:unknown_project, String.t()}
          | {:rmap_not_found, String.t()}
          | :no_pending_task
          | {:task_not_found, String.t()}
          | :roadmap_not_found
          | {:rmap_failed, [String.t()], integer(), String.t()}
          | {:rmap_bad_output, term()}

  @typep ctx :: %{root: String.t(), tasks_path: String.t(), rmap_bin: String.t()}
  @typep failure :: {integer(), String.t(), [String.t()]}

  api(:ingest, "Fetch a roadmap task via rmap and render it as a ready-to-dispatch agent prompt.",
    params: [
      selector: [
        kind: :value,
        description:
          "Task selector. :next picks the next pending task by rmap's D/B/U scoring; {:id, id} fetches a specific task by id string."
      ],
      opts: [
        kind: :value,
        default: [],
        description:
          "Keyword list. :project (%Harness.Project{} — uses project.roadmap_path; SOURCE the project from Harness.ProjectRegistry.lookup/1). :project_root (directory holding roadmap/tasks.toml — fallback when :project omitted; defaults to File.cwd!/0). :agent (atom :claude/:codex/:cursor/:grok/:antigravity/:pi — which agent rmap delegate renders the prompt for; defaults to :claude). :rmap_bin (rmap executable path; defaults to \"rmap\")."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %Harness.Roadmap.Item{}} carrying id, title, prompt, agent, body (or nil), and acceptance_criteria (a list, empty when the task declares none). {:error, reason} per t:error/0 (invalid_agent, rmap_not_found, no_pending_task, task_not_found, roadmap_not_found, rmap_failed, rmap_bad_output)."
    }
  )

  @spec ingest(selector(), keyword()) :: {:ok, Item.t()} | {:error, error()}
  def ingest(selector, opts \\ []) do
    agent = Keyword.get(opts, :agent, :claude)
    rmap_bin = Keyword.get(opts, :rmap_bin, "rmap")

    with {:ok, ctx} <- build_ctx(opts),
         :ok <- validate_agent(agent),
         :ok <- ensure_rmap(rmap_bin),
         {:ok, task} <- fetch_task(selector, ctx),
         {:ok, prompt} <- render_prompt(task["id"], agent, ctx) do
      {:ok,
       %Item{
         id: task["id"],
         title: task["title"],
         prompt: prompt,
         agent: agent,
         body: task["body"],
         acceptance_criteria: acceptance_criteria(task),
         domains: task_domains(task),
         d: task_d_score(task),
         markers: task_markers(task),
         model: task_model(task)
       }}
    end
  end

  # rmap emits `acceptance_criteria` as a JSON array of strings; a task that
  # declares none omits the key (or, defensively, emits null). Either way the
  # Item must carry an empty list, never crash — the semantic gate iterates it.
  @spec acceptance_criteria(map()) :: [String.t()]
  defp acceptance_criteria(%{"acceptance_criteria" => criteria}) when is_list(criteria), do: criteria
  defp acceptance_criteria(_task), do: []

  @spec task_domains(map()) :: [CapabilityDomain.t()]
  defp task_domains(%{"domains" => domains}) when is_list(domains) do
    domains
    |> Enum.map(&domain_atom/1)
    |> CapabilityDomain.normalize()
  end

  defp task_domains(_task), do: []

  @spec domain_atom(term()) :: atom() | term()
  defp domain_atom(domain) when is_binary(domain) do
    String.to_existing_atom(domain)
  rescue
    ArgumentError -> domain
  end

  defp domain_atom(domain), do: domain

  # rmap nests the difficulty score under `scores.d`; a task without scores omits
  # the key. Carried structurally so the in-run discernment gate reads the typed
  # field instead of regex-scraping `D:X` from the rendered prompt.
  @spec task_d_score(map()) :: non_neg_integer() | nil
  defp task_d_score(%{"scores" => %{"d" => d}}) when is_integer(d) and d >= 0, do: d
  defp task_d_score(_task), do: nil

  # rmap emits `markers` as a JSON array of strings from a closed enum
  # (parallel | cx | csr | bug | security | docs | handbuild). Convert to atoms
  # so the stakes gate matches `:security` / `:bug` typed values; an unknown
  # marker (no existing atom) falls back to its string, never crashing.
  @spec task_markers(map()) :: [atom() | String.t()]
  defp task_markers(%{"markers" => markers}) when is_list(markers), do: Enum.map(markers, &marker_atom/1)
  defp task_markers(_task), do: []

  @spec marker_atom(term()) :: atom() | term()
  defp marker_atom(marker) when is_binary(marker) do
    String.to_existing_atom(marker)
  rescue
    ArgumentError -> marker
  end

  defp marker_atom(marker), do: marker

  @spec task_model(map()) :: String.t() | nil
  defp task_model(%{"model" => model}) when is_binary(model) and model != "", do: model
  defp task_model(_task), do: nil

  api(:ready, "List the parallel-safe, headless-dispatchable task set via rmap ready --dispatchable.",
    params: [
      opts: [
        kind: :value,
        default: [],
        description:
          "Keyword list. Working-root precedence as ingest/2: :project (%Harness.Project{} — uses project.roadmap_path; SOURCE from Harness.ProjectRegistry.lookup/1) > :project_name > :project_root (defaults to File.cwd!/0). :rmap_bin (rmap executable path; defaults to \"rmap\")."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, [task_map]} — every pending task whose deps are all done, excluding handbuild-marked tasks; mutually independent by construction, safe to fan out as one batch. Each map carries the --fields-projected keys id, assignee, markers — enough to route each task to its agent without a second rmap call. {:error, reason} per t:error/0 (unknown_project, rmap_not_found, roadmap_not_found, rmap_failed, rmap_bad_output)."
    }
  )

  @spec ready(keyword()) :: {:ok, [map()]} | {:error, error()}
  def ready(opts \\ []) do
    with {:ok, ctx} <- build_ctx(opts),
         :ok <- ensure_rmap(ctx.rmap_bin),
         {:ok, output} <- run_ready(ctx) do
      decode_ready(output)
    end
  end

  api(:list, "List a registered project's roadmap tasks as structured data (optionally by status) via rmap.",
    params: [
      project_name: [
        kind: :value,
        description:
          "Registered project name; resolved via Harness.ProjectRegistry.lookup/1 to its roadmap_path. SOURCE valid names from project_registry-list."
      ],
      status: [
        kind: :value,
        default: nil,
        description:
          "Optional rmap status filter: pending | in_progress | blocked | done | superseded. Omit for all tasks. Finer filtering (phase/marker/bundle/milestone) is client-side on the returned list — each task map carries those fields."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, [task_map]} — each map carries id, title, status, phase, bundle, eff, markers, milestone. {:error, reason}: unknown_project, rmap_not_found, roadmap_not_found, rmap_failed, rmap_bad_output."
    }
  )

  @spec list(String.t(), String.t() | nil) :: {:ok, [map()]} | {:error, error()}
  def list(project_name, status \\ nil) when is_binary(project_name) do
    with {:ok, ctx} <- build_ctx(project_name: project_name),
         :ok <- ensure_rmap(ctx.rmap_bin),
         {:ok, output} <- run_list(status, ctx) do
      decode_task_list(output)
    end
  end

  api(
    :next_bundle,
    "Fetch the next session-sized bundle of pending tasks for a registered project as structured data via rmap.",
    params: [
      project_name: [
        kind: :value,
        description:
          "Registered project name; resolved via Harness.ProjectRegistry.lookup/1 to its roadmap_path. SOURCE valid names from project_registry-list."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{bundle: bundle_meta | nil, tasks: [task_map]}} — bundle_meta carries name/phase/description; tasks are the bundle's pending tasks (id, title, eff, ...). {:error, reason} per the same set as list/2."
    }
  )

  @spec next_bundle(String.t()) :: {:ok, %{bundle: map() | nil, tasks: [map()]}} | {:error, error()}
  def next_bundle(project_name) when is_binary(project_name) do
    with {:ok, ctx} <- build_ctx(project_name: project_name),
         :ok <- ensure_rmap(ctx.rmap_bin),
         {:ok, output} <- run_bundle(ctx) do
      decode_bundle(output)
    end
  end

  api(:mark_landed, """
  Writes the outcome of a successful autonomous land back to rmap.

  Transitions the task to `done` with `verified=true` and the landed commit SHA
  as `shipped_in`, via `rmap status <id> done --verified --shipped-in <sha>`
  (plus `--delivered-by` / `--implemented` when supplied). This is the
  merge-train lander's writeback step; the implementer dispatched the work, the
  verification stack graded it green post-integration, so `verified` is honest.

  Options:

    * `:project` — a `%Harness.Project{}`. When it carries a `target_branch`
      and a local source, the transition is pushed durably to that branch (see
      "Durability" below); otherwise this supplies the local-write root.
    * `:root` — the project root holding `roadmap/tasks.toml`. Required unless
      `:project` is given (then `project.roadmap_path` is used).
    * `:sha` — the landed commit SHA recorded as `shipped_in` (required).
    * `:delivered_by` — agent string for `--delivered-by` (optional).
    * `:implemented` — what shipped, for `--implemented` (optional).
    * `:rmap_bin` — override the `rmap` binary name/path (intended for tests).

  Returns `{:ok, output}` or `{:error, {status, output, args}}`.

  ## Durability

  When `:project` carries a `target_branch` + local source, the transition is a
  durable git operation — fetch the target, mutate a fresh detached worktree at
  its tip, commit, and ff-push (`Harness.Roadmap.Durable`) — so concurrent
  writers never clobber each other's roadmap edits. Lacking such a project it
  falls back to a plain local rmap write.

  > Depends on rmap's `--shipped-in` status flag (rmap roadmap Task 33).
  """)

  @spec mark_landed(Item.t() | String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def mark_landed(item_or_id, opts) do
    sha = Keyword.fetch!(opts, :sha)

    status_args =
      ["done", "--verified", "--shipped-in", sha]
      |> append_flag("--delivered-by", opts[:delivered_by])
      |> append_flag("--implemented", opts[:implemented])

    mutate(item_or_id, status_args, "done (shipped #{short_sha(sha)})", opts)
  end

  api(:mark_blocked, """
  Routes a task to `blocked` with a structured reason — the lander's terminal sink.

  Transitions the task to `blocked` via `rmap status <id> blocked --reason "<reason>"`.
  When the merge-train exhausts its landing-attempt cap (a post-merge-red or
  conflict that a fresh re-dispatch could not resolve), the task is parked
  `blocked` so `rmap next` skips it and a human/orchestrator can read *why*
  without opening `tasks.toml`. Without a sink the loop would silently retry
  forever — this is the honest dead end.

  Options:

    * `:project` — a `%Harness.Project{}`; with a `target_branch` + local source
      the transition is pushed durably to that branch, else supplies the
      local-write root (see `mark_landed/2` § Durability).
    * `:root` — the project root holding `roadmap/tasks.toml`. Required unless
      `:project` is given.
    * `:reason` — the structured blocked reason (required; rmap mandates a
      reason on `blocked` transitions, auto-cleared when the task leaves blocked).
    * `:rmap_bin` — override the `rmap` binary name/path (intended for tests).

  Returns `{:ok, output}` or `{:error, {status, output, args}}`.

  > Depends on rmap's `--reason` status flag + `blocked_reason` field.
  """)

  @spec mark_blocked(Item.t() | String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def mark_blocked(item_or_id, opts) do
    reason = Keyword.fetch!(opts, :reason)
    mutate(item_or_id, ["blocked", "--reason", reason], "blocked", opts)
  end

  api(:mark_in_progress, """
  Transitions a dispatched task to `in_progress` (best-effort) so `rmap ready` / `next`
  no longer return it for re-dispatch.

  Owned by the run lifecycle (Harness.Run.Worker), not the poller. Called on run
  start; a writeback failure logs but does not fail the run. A green-but-unlanded
  run (landing_policy :manual) stays `in_progress` — this stops the "completed green
  re-dispatched every tick" loop. Terminal run failure reverts to `pending` (not
  `blocked`; blocked is the lander's sink only).

  Options:

    * `:project` — a `%Harness.Project{}`; with a `target_branch` + local source
      the transition is pushed durably to that branch, else supplies the
      local-write root (see `mark_landed/2` § Durability).
    * `:root` — the project root holding `roadmap/tasks.toml`. Required unless
      `:project` is given.
    * `:rmap_bin` — override the `rmap` binary name/path (intended for tests).

  Returns `{:ok, output}` or `{:error, {status, output, args}}`.
  """)

  @spec mark_in_progress(Item.t() | String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def mark_in_progress(item_or_id, opts) do
    mutate(item_or_id, ["in_progress"], "in_progress", opts)
  end

  api(:mark_pending, """
  Reverts a task to `pending` after a terminal run failure (red after repairs
  exhausted, or run crash) so a later poller tick can retry it.

  Only for ordinary run failures — lander terminal exhaustion uses `mark_blocked`.

  Options: `:project` (durable push when it has a `target_branch` + local source,
  see `mark_landed/2` § Durability), `:root` (required unless `:project` is
  given), `:rmap_bin` (for tests).

  Returns `{:ok, output}` or `{:error, {status, output, args}}`.
  """)

  @spec mark_pending(Item.t() | String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def mark_pending(item_or_id, opts) do
    mutate(item_or_id, ["pending"], "pending", opts)
  end

  # The single chokepoint every mark_* transition funnels through. Builds the
  # rmap `status` argv, then either pushes it durably to the project's target
  # branch (when a usable %Project{} is supplied — see `durable_target/1`) or
  # falls back to a plain local rmap write (the historical best-effort path,
  # kept for callers that pass only `:root`, e.g. tests and target-branch-less
  # projects).
  @spec mutate(Item.t() | String.t(), [String.t()], String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp mutate(item_or_id, status_args, label, opts) do
    ctx = landing_ctx(opts)
    task_id = landing_task_id(item_or_id)
    args = ["status", task_id | status_args]

    with :ok <- ensure_rmap(ctx.rmap_bin) do
      apply_mutation(args, ctx, opts, task_id, label)
    end
  end

  @spec apply_mutation([String.t()], ctx(), keyword(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp apply_mutation(args, ctx, opts, task_id, label) do
    case durable_target(opts) do
      {:ok, repo, target} ->
        Durable.commit(repo, target,
          message: "roadmap: task #{task_id} -> #{label}",
          apply: fn root -> run_rmap(args, durable_ctx(root, ctx.rmap_bin)) end
        )

      :none ->
        run_rmap(args, ctx)
    end
  end

  # A durable write needs a local repo to push from and a branch to push to. A
  # project missing either — no `target_branch`, or a `{:github, _}` source with
  # no operable local checkout — falls back to the plain local rmap write.
  @spec durable_target(keyword()) :: {:ok, String.t(), String.t()} | :none
  defp durable_target(opts) do
    with %Project{target_branch: target} = project when is_binary(target) and target != "" <-
           Keyword.get(opts, :project),
         {:ok, repo} <- Project.local_repo_path(project) do
      {:ok, repo, target}
    else
      _ -> :none
    end
  end

  @spec durable_ctx(String.t(), String.t()) :: ctx()
  defp durable_ctx(root, rmap_bin) do
    %{root: root, tasks_path: Path.join(root, "roadmap/tasks.toml"), rmap_bin: rmap_bin}
  end

  @spec short_sha(String.t()) :: String.t()
  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 12)

  # Builds the rmap context for the mark_* transitions. The local-write root is
  # an explicit `:root`, or `project.roadmap_path` when only `:project` is given
  # (unlike `build_ctx/1`, whose root resolution falls back to registry / cwd).
  @spec landing_ctx(keyword()) :: ctx()
  defp landing_ctx(opts) do
    root = landing_root(opts)

    %{
      root: root,
      tasks_path: Path.join(root, "roadmap/tasks.toml"),
      rmap_bin: Keyword.get(opts, :rmap_bin, "rmap")
    }
  end

  @spec landing_root(keyword()) :: String.t()
  defp landing_root(opts) do
    case {Keyword.get(opts, :root), Keyword.get(opts, :project)} do
      {root, _project} when is_binary(root) -> root
      {_root, %Project{roadmap_path: path}} -> path
      _ -> raise ArgumentError, "Harness.Roadmap mark_* requires :root or :project"
    end
  end

  @spec landing_task_id(Item.t() | String.t()) :: String.t()
  defp landing_task_id(%Item{id: id}), do: to_string(id)
  defp landing_task_id(id) when is_binary(id), do: id

  @spec append_flag([String.t()], String.t(), String.t() | nil) :: [String.t()]
  defp append_flag(args, _flag, nil), do: args
  defp append_flag(args, flag, value) when is_binary(value), do: args ++ [flag, value]

  @spec build_ctx(keyword()) :: {:ok, ctx()} | {:error, error()}
  defp build_ctx(opts) do
    with {:ok, root} <- resolve_root(opts) do
      {:ok,
       %{
         root: root,
         tasks_path: Path.join(root, "roadmap/tasks.toml"),
         rmap_bin: Keyword.get(opts, :rmap_bin, "rmap")
       }}
    end
  end

  # Working-root precedence: an explicit %Project{} struct, then a registered
  # project name (resolved via ProjectRegistry — the JSON-native path the MCP
  # orchestrator uses), then a literal project_root, finally cwd.
  @spec resolve_root(keyword()) :: {:ok, String.t()} | {:error, {:unknown_project, String.t()}}
  defp resolve_root(opts) do
    project = Keyword.get(opts, :project)
    project_name = Keyword.get(opts, :project_name)

    cond do
      match?(%Project{}, project) ->
        {:ok, Path.expand(project.roadmap_path)}

      is_binary(project_name) ->
        case ProjectRegistry.lookup(project_name) do
          {:ok, %Project{roadmap_path: path}} -> {:ok, Path.expand(path)}
          {:error, _} -> {:error, {:unknown_project, project_name}}
        end

      true ->
        {:ok, opts |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()}
    end
  end

  @spec validate_agent(term()) :: :ok | {:error, {:invalid_agent, term()}}
  defp validate_agent(agent) when agent in @valid_agents, do: :ok
  defp validate_agent(agent), do: {:error, {:invalid_agent, agent}}

  @spec ensure_rmap(String.t()) :: :ok | {:error, {:rmap_not_found, String.t()}}
  defp ensure_rmap(rmap_bin) do
    if System.find_executable(rmap_bin) || executable_file?(rmap_bin),
      do: :ok,
      else: {:error, {:rmap_not_found, rmap_bin}}
  end

  # `System.find_executable/1` only searches PATH for bare names; an explicit
  # path (e.g. a test stub at /tmp/.../rmap, or an absolute install path) is
  # accepted when it points at a regular file on disk.
  @spec executable_file?(String.t()) :: boolean()
  defp executable_file?(path), do: String.contains?(path, "/") and File.regular?(path)

  # rmap next has no "next" mode in `delegate`, so :next is resolved in two
  # steps: discover the id here, then render the prompt from it.
  @spec fetch_task(selector(), ctx()) :: {:ok, map()} | {:error, error()}
  defp fetch_task(:next, ctx) do
    case run_rmap(["next", "--json"], ctx) do
      {:ok, output} -> decode_task(output)
      {:error, failure} -> {:error, classify_failure(failure, nil)}
    end
  end

  defp fetch_task({:id, id}, ctx) when is_binary(id) do
    case run_rmap(["show", id, "--json"], ctx) do
      {:ok, output} -> decode_task(output)
      {:error, failure} -> {:error, classify_failure(failure, id)}
    end
  end

  defp fetch_task(other, _ctx), do: {:error, {:invalid_selector, other}}

  # The success gate for a --json call is JSON-decode success, not exit 0:
  # rmap can print an error to stdout and still exit 0 (e.g. a directory path).
  # The id is normalized to a string: rmap faithfully emits whatever type the
  # project's tasks.toml uses, so a project keyed on integer ids (`id = 25`)
  # yields a JSON integer. Item.id is String.t() and the id flows into a
  # `rmap delegate <id>` System.cmd arg (which must be a string), so coerce here.
  @spec decode_task(String.t()) :: {:ok, map()} | {:error, error()}
  defp decode_task(output) do
    case JSON.decode(output) do
      {:ok, nil} -> {:error, :no_pending_task}
      {:ok, %{"id" => id} = task} when is_binary(id) -> {:ok, task}
      {:ok, %{"id" => id} = task} when is_integer(id) -> {:ok, %{task | "id" => Integer.to_string(id)}}
      {:ok, other} -> {:error, {:rmap_bad_output, {:unexpected_json, other}}}
      {:error, reason} -> {:error, {:rmap_bad_output, reason}}
    end
  end

  @spec render_prompt(String.t(), atom(), ctx()) :: {:ok, String.t()} | {:error, error()}
  defp render_prompt(id, agent, ctx) do
    case run_rmap(["delegate", id, "--to", Atom.to_string(agent)], ctx) do
      {:ok, output} -> {:ok, output}
      {:error, failure} -> {:error, classify_failure(failure, id)}
    end
  end

  @spec run_list(String.t() | nil, ctx()) :: {:ok, String.t()} | {:error, error()}
  defp run_list(status, ctx) do
    case run_rmap(["list", "--json"] ++ status_argv(status), ctx) do
      {:ok, output} -> {:ok, output}
      {:error, failure} -> {:error, classify_failure(failure, nil)}
    end
  end

  @spec status_argv(String.t() | nil) :: [String.t()]
  defp status_argv(nil), do: []
  defp status_argv(status), do: ["--status", to_string(status)]

  # `--dispatchable` drops handbuild tasks; `--fields` projects to a bare JSON
  # array of just the routing-relevant keys (and implies --json).
  @spec run_ready(ctx()) :: {:ok, String.t()} | {:error, error()}
  defp run_ready(ctx) do
    case run_rmap(["ready", "--dispatchable", "--fields", "id,assignee,markers"], ctx) do
      {:ok, output} -> {:ok, output}
      {:error, failure} -> {:error, classify_failure(failure, nil)}
    end
  end

  # `rmap ready --fields ...` emits a bare JSON array (one object per task); an
  # empty dispatchable set yields `[]`.
  @spec decode_ready(String.t()) :: {:ok, [map()]} | {:error, error()}
  defp decode_ready(output) do
    case JSON.decode(output) do
      {:ok, tasks} when is_list(tasks) -> {:ok, tasks}
      {:ok, other} -> {:error, {:rmap_bad_output, {:unexpected_json, other}}}
      {:error, reason} -> {:error, {:rmap_bad_output, reason}}
    end
  end

  # `rmap list --json` returns the full roadmap envelope; the task array lives
  # under the singular "task" key. An empty roadmap yields an empty list.
  @spec decode_task_list(String.t()) :: {:ok, [map()]} | {:error, error()}
  defp decode_task_list(output) do
    case JSON.decode(output) do
      {:ok, %{"task" => tasks}} when is_list(tasks) -> {:ok, tasks}
      {:ok, other} -> {:error, {:rmap_bad_output, {:unexpected_json, other}}}
      {:error, reason} -> {:error, {:rmap_bad_output, reason}}
    end
  end

  @spec run_bundle(ctx()) :: {:ok, String.t()} | {:error, error()}
  defp run_bundle(ctx) do
    case run_rmap(["next-bundle", "--json"], ctx) do
      {:ok, output} -> {:ok, output}
      {:error, failure} -> {:error, classify_failure(failure, nil)}
    end
  end

  # `rmap next-bundle --json` carries the bundle metadata under "bundle" and the
  # task array under "tasks" (a sibling key, not nested in the metadata).
  @spec decode_bundle(String.t()) :: {:ok, %{bundle: map() | nil, tasks: [map()]}} | {:error, error()}
  defp decode_bundle(output) do
    case JSON.decode(output) do
      {:ok, %{"tasks" => tasks} = envelope} when is_list(tasks) ->
        {:ok, %{bundle: Map.get(envelope, "bundle"), tasks: tasks}}

      {:ok, other} ->
        {:error, {:rmap_bad_output, {:unexpected_json, other}}}

      {:error, reason} ->
        {:error, {:rmap_bad_output, reason}}
    end
  end

  # Every rmap call targets the roadmap with an explicit --tasks-path so it
  # never ancestor-walks into a different roadmap; `cd:` is belt-and-suspenders.
  @spec run_rmap([String.t()], ctx()) :: {:ok, String.t()} | {:error, failure()}
  # System.cmd/3 with an argv list spawns directly — no shell, no interpolation.
  # rmap_bin and args are harness-constructed, not external input.
  # sobelow_skip ["CI.System"]
  defp run_rmap(argv, ctx) do
    args = argv ++ ["--tasks-path", ctx.tasks_path]
    base_opts = [stderr_to_stdout: true]
    opts = if File.dir?(ctx.root), do: [{:cd, ctx.root} | base_opts], else: base_opts

    case System.cmd(ctx.rmap_bin, args, opts) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output, args}}
    end
  end

  # rmap (../rmap, ours) emits structured exit codes for the classifiable
  # failures so harness branches on the contract, not on English stderr:
  # 3 = task <id> not found, 4 = the roadmap is unreadable/missing/malformed TOML.
  # Anything else is an unclassified rmap failure. rmap is always given an
  # explicit --tasks-path, so its ancestor-walk "could not find roadmap" path is
  # unreachable here. Exit 3 only arises from a `show`/`delegate` call (both
  # carry an id), so the is_binary(id) guard is belt-and-suspenders.
  @rmap_exit_task_not_found 3
  @rmap_exit_invalid_roadmap 4

  @spec classify_failure(failure(), String.t() | nil) :: error()
  defp classify_failure({@rmap_exit_task_not_found, _output, _args}, id) when is_binary(id), do: {:task_not_found, id}

  defp classify_failure({@rmap_exit_invalid_roadmap, _output, _args}, _id), do: :roadmap_not_found

  defp classify_failure({status, output, args}, _id), do: {:rmap_failed, args, status, output}
end
