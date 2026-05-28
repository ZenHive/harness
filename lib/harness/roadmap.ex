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

  ## Non-delegatable Adapters Contract

  Non-delegatable adapters (such as `Grok` and `Antigravity`) are not valid targets
  for rmap delegation (`rmap delegate --to` accepts only `claude`, `codex`, or `cursor`).
  Therefore, passing `:grok` or `:antigravity` as the `:agent` option to `ingest/2` is
  rejected by design.

  To run a task using a non-delegatable adapter:
  1. Ingest the task using a delegatable agent (e.g. `:claude`, `:codex`, or `:cursor`),
     which produces a `Harness.Roadmap.Item` with the corresponding rendered prompt.
  2. Dispatch that item directly to the non-delegatable adapter module (e.g.
     `Harness.AgentAdapter.Grok` or `Harness.AgentAdapter.Antigravity`) via
     `Harness.Run.Supervisor.start_run/4` (or via `Harness.Batch` using the adapter module).
  """

  use Descripex, namespace: "/roadmap"

  alias Harness.Project
  alias Harness.Roadmap.Item

  # Mirrors `rmap delegate --to`'s accepted values exactly — ingestion shells
  # out to `rmap delegate` to render the prompt, so an agent rmap cannot
  # delegate to (e.g. :grok, :antigravity) is rejected here rather than failing
  # downstream with an opaque `{:rmap_failed, _}`.
  #
  # Contract for non-delegatable adapters: Grok and Antigravity run with a
  # claude/codex/cursor-rendered prompt. Ingestion rejects them on the ingest
  # surface, but they can be run by dispatching the ingested item directly to their
  # adapter module via `Harness.Run.Supervisor.start_run/4`.
  @valid_agents [:claude, :codex, :cursor]

  @typedoc "Which task to ingest: the next pending one, or one named by id."
  @type selector :: :next | {:id, String.t()}

  @typedoc "A reason `ingest/2` can fail with."
  @type error ::
          {:invalid_agent, term()}
          | {:invalid_selector, term()}
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
          "Keyword list. :project (%Harness.Project{} — uses project.roadmap_path; SOURCE the project from Harness.ProjectRegistry.lookup/1). :project_root (directory holding roadmap/tasks.toml — fallback when :project omitted; defaults to File.cwd!/0). :agent (atom :claude/:codex/:cursor — which agent rmap delegate renders the prompt for; defaults to :claude). :rmap_bin (rmap executable path; defaults to \"rmap\")."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %Harness.Roadmap.Item{}} carrying id, title, prompt, agent. {:error, reason} per t:error/0 (invalid_agent, rmap_not_found, no_pending_task, task_not_found, roadmap_not_found, rmap_failed, rmap_bad_output)."
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
      {:ok, %Item{id: task["id"], title: task["title"], prompt: prompt, agent: agent}}
    end
  end

  @spec build_ctx(keyword()) :: {:ok, ctx()} | {:error, error()}
  defp build_ctx(opts) do
    root =
      case Keyword.get(opts, :project) do
        %Project{roadmap_path: path} -> Path.expand(path)
        _ -> opts |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()
      end

    {:ok,
     %{
       root: root,
       tasks_path: Path.join(root, "roadmap/tasks.toml"),
       rmap_bin: Keyword.get(opts, :rmap_bin, "rmap")
     }}
  end

  @spec validate_agent(term()) :: :ok | {:error, {:invalid_agent, term()}}
  defp validate_agent(agent) when agent in @valid_agents, do: :ok
  defp validate_agent(agent), do: {:error, {:invalid_agent, agent}}

  @spec ensure_rmap(String.t()) :: :ok | {:error, {:rmap_not_found, String.t()}}
  defp ensure_rmap(rmap_bin) do
    if System.find_executable(rmap_bin), do: :ok, else: {:error, {:rmap_not_found, rmap_bin}}
  end

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
  @spec decode_task(String.t()) :: {:ok, map()} | {:error, error()}
  defp decode_task(output) do
    case JSON.decode(output) do
      {:ok, nil} -> {:error, :no_pending_task}
      {:ok, %{"id" => id} = task} when is_binary(id) -> {:ok, task}
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

  # An unreadable, missing, or malformed roadmap file surfaces as an
  # "invalid TOML" error; a missing task as "task <id> not found". Anything
  # else is an unclassified rmap failure. rmap is always given an explicit
  # --tasks-path, so its ancestor-walk "could not find roadmap" path is
  # unreachable here.
  @spec classify_failure(failure(), String.t() | nil) :: error()
  defp classify_failure({status, output, args}, id) do
    cond do
      is_binary(id) and Regex.match?(~r/task .+ not found/i, output) -> {:task_not_found, id}
      String.contains?(output, "invalid TOML") -> :roadmap_not_found
      true -> {:rmap_failed, args, status, output}
    end
  end
end
