defmodule Harness.Dispatch.AgentGate do
  @moduledoc false
  # Mechanical plumbing shared by the operator-triggered agent-gate dispatchers
  # (`Harness.DependencyBump`, `Harness.ToolingBaseline.Dispatch`): resolve the
  # project, render task TOML, create rmap tasks, ingest them, and enqueue
  # reviewer-gated runs. It installs, builds, and verifies nothing itself — the
  # implementer and reviewer agents do that. Each dispatcher keeps its own
  # spec-shaping and result-map building; only the plumbing lives here so the
  # two paths share it rather than duplicating it.

  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Roadmap
  alias Harness.Roadmap.Item
  alias Harness.Run.Worker, as: RunWorker

  @task_id_line_regex ~r/created task(?:s)? (.+)/

  @type task_creator :: (Project.t(), [struct()], String.t(), String.t() | nil ->
                           {:ok, [String.t()]} | {:error, term()})
  @type enqueuer :: (Project.t(), Item.t(), module(), keyword() ->
                       {:ok, String.t(), Oban.Job.t()} | {:error, term()})
  @type result_builder :: (struct(), String.t(), String.t() -> map())

  @doc "Resolve a registered project by name, normalizing the not-found error."
  @spec lookup_project(String.t()) :: {:ok, Project.t()} | {:error, {:unknown_project, String.t()}}
  def lookup_project(project_name) do
    case ProjectRegistry.lookup(project_name) do
      {:ok, %Project{} = project} -> {:ok, project}
      {:error, _reason} -> {:error, {:unknown_project, project_name}}
    end
  end

  @doc """
  Create rmap tasks for `specs`, then ingest and enqueue a reviewer-gated run per task.

  `opts` supplies the per-dispatcher wiring: `:creator` and `:enqueuer` functions,
  the resolved `:adapter_pair`, the `:scrub` flag, and `:build_result` — a
  `(spec, task_id, run_id -> map())` that shapes each returned task entry. Halts
  and returns the first error.
  """
  @spec create_and_enqueue(Project.t(), [struct()], String.t(), String.t() | nil, keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def create_and_enqueue(%Project{} = project, specs, adapter, model, opts) do
    creator = Keyword.fetch!(opts, :creator)

    with {:ok, task_ids} <- create_tasks(project, specs, adapter, model, creator) do
      enqueue_tasks(specs, task_ids, fn spec, task_id -> enqueue_one(project, spec, task_id, opts) end)
    end
  end

  @spec enqueue_one(Project.t(), struct(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp enqueue_one(%Project{} = project, spec, task_id, opts) do
    enqueuer = Keyword.fetch!(opts, :enqueuer)
    {adapter_module, render_agent} = Keyword.fetch!(opts, :adapter_pair)
    scrub = Keyword.fetch!(opts, :scrub)
    build_result = Keyword.fetch!(opts, :build_result)

    case ingest_and_enqueue(project, task_id, adapter_module, render_agent, enqueuer, spec.check_command, scrub) do
      {:ok, _item, run_id} -> {:ok, build_result.(spec, task_id, run_id)}
      {:error, _reason} = error -> error
    end
  end

  @spec create_tasks(Project.t(), [struct()], String.t(), String.t() | nil, task_creator()) ::
          {:ok, [String.t()]} | {:error, term()}
  defp create_tasks(%Project{}, [], _adapter, _model, _creator), do: {:ok, []}

  defp create_tasks(%Project{} = project, specs, adapter, model, creator) do
    case creator.(project, specs, adapter, model) do
      {:ok, task_ids} when is_list(task_ids) -> {:ok, Enum.map(task_ids, &to_string/1)}
      {:error, _reason} = error -> error
    end
  end

  @spec enqueue_tasks([struct()], [String.t()], (struct(), String.t() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  defp enqueue_tasks([], [], _enqueue_one), do: {:ok, []}

  defp enqueue_tasks(specs, task_ids, enqueue_one) do
    specs
    |> Enum.zip(task_ids)
    |> Enum.reduce_while({:ok, []}, fn {spec, task_id}, {:ok, acc} ->
      case enqueue_one.(spec, task_id) do
        {:ok, task} -> {:cont, {:ok, [task | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, tasks} -> {:ok, Enum.reverse(tasks)}
      {:error, _reason} = error -> error
    end
  end

  @spec ingest_and_enqueue(Project.t(), String.t(), module(), atom(), enqueuer(), String.t(), boolean()) ::
          {:ok, Item.t(), String.t()} | {:error, term()}
  defp ingest_and_enqueue(%Project{} = project, task_id, adapter_module, render_agent, enqueuer, check_command, scrub) do
    with {:ok, item} <- ingest_task(task_id, project, render_agent),
         {:ok, run_id, _job} <-
           enqueuer.(project, item, adapter_module,
             env: scrub_env(scrub),
             check_command: check_command,
             requested_model: item.model
           ) do
      {:ok, item, run_id}
    end
  end

  @spec ingest_task(String.t(), Project.t(), atom()) :: {:ok, Item.t()} | {:error, term()}
  defp ingest_task(task_id, %Project{} = project, render_agent) do
    case Application.get_env(:harness, :roadmap_ingest) do
      fun when is_function(fun, 2) -> fun.({:id, task_id}, project: project, agent: render_agent)
      _other -> Roadmap.ingest({:id, task_id}, project: project, agent: render_agent)
    end
  end

  @doc "Resolve the task creator from `config_key`, defaulting to the caller-supplied function."
  @spec task_creator(atom(), task_creator()) :: task_creator()
  def task_creator(config_key, default) when is_atom(config_key) and is_function(default, 4) do
    Application.get_env(:harness, config_key, default)
  end

  @doc "Resolve the run enqueuer from `config_key`, defaulting to `Harness.Run.Worker.enqueue/4`."
  @spec enqueuer(atom()) :: enqueuer()
  def enqueuer(config_key) when is_atom(config_key) do
    Application.get_env(:harness, config_key, &RunWorker.enqueue/4)
  end

  @doc "Run `rmap new --from-stdin` for the rendered TOML and parse the created ids."
  @spec run_rmap_new(Project.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def run_rmap_new(%Project{} = project, input) when is_binary(input) do
    args = ["new", "--from-stdin", "--tasks-path", tasks_path(project)]

    case System.cmd("rmap", args, input: input, cd: project.roadmap_path, stderr_to_stdout: true) do
      {output, 0} -> parse_created_ids(output)
      {output, status} -> {:error, {:rmap_failed, args, status, output}}
    end
  rescue
    error in ErlangError -> {:error, {:rmap_spawn_failed, ["new", "--from-stdin"], Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:rmap_spawn_failed, ["new", "--from-stdin"], reason}}
  end

  @doc "Absolute path to a project's `roadmap/tasks.toml`."
  @spec tasks_path(Project.t()) :: String.t()
  def tasks_path(%Project{} = project), do: Path.join(project.roadmap_path, "roadmap/tasks.toml")

  @doc "Render one `[[task]]` TOML block from the given fields."
  @spec task_block(keyword()) :: String.t()
  def task_block(fields) do
    scores = Keyword.fetch!(fields, :scores)

    [
      "[[task]]",
      "phase = #{Keyword.fetch!(fields, :phase)}",
      "bundle = #{toml_string(Keyword.fetch!(fields, :bundle))}",
      "title = #{toml_string(Keyword.fetch!(fields, :title))}",
      "scores = { d = #{scores.d}, b = #{scores.b}, u = #{scores.u} }",
      assignee_line(Keyword.fetch!(fields, :adapter)),
      model_line(Keyword.fetch!(fields, :model)),
      "body = #{toml_string(Keyword.fetch!(fields, :body))}",
      "acceptance_criteria = #{toml_array(Keyword.fetch!(fields, :acceptance_criteria))}",
      "files_to_modify = #{toml_array(Keyword.fetch!(fields, :files_to_modify))}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc "Env override that scrubs `ANTHROPIC_API_KEY` from the agent Port when `true`."
  @spec scrub_env(boolean()) :: %{optional(String.t()) => false}
  def scrub_env(true), do: %{"ANTHROPIC_API_KEY" => false}
  def scrub_env(false), do: %{}

  @spec parse_created_ids(String.t()) :: {:ok, [String.t()]} | {:error, {:rmap_bad_output, String.t()}}
  defp parse_created_ids(output) do
    ids =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&created_ids_from_line/1)

    if ids == [], do: {:error, {:rmap_bad_output, output}}, else: {:ok, ids}
  end

  @spec created_ids_from_line(String.t()) :: [String.t()]
  defp created_ids_from_line(line) do
    case Regex.run(@task_id_line_regex, line, capture: :all_but_first) do
      [ids] -> ids |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      _none -> []
    end
  end

  @spec assignee_line(String.t()) :: String.t()
  defp assignee_line("recommend"), do: ""
  defp assignee_line(adapter), do: "assignee = #{toml_string(adapter)}"

  @spec model_line(String.t() | nil) :: String.t()
  defp model_line(nil), do: ""
  defp model_line(model), do: "model = #{toml_string(model)}"

  @spec toml_string(String.t()) :: String.t()
  defp toml_string(value) when is_binary(value), do: Jason.encode!(value)

  @spec toml_array([String.t()]) :: String.t()
  defp toml_array(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &toml_string/1) <> "]"
  end
end
