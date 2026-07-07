defmodule Harness.Run.Actions.Worktree do
  @moduledoc false

  import Harness.Run.Actions.Timeouts, only: [implementer_idle_timeout: 1]

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.AgentRules
  alias Harness.Config
  alias Harness.Git
  alias Harness.Project
  alias Harness.Roadmap.Item
  alias Harness.Run.Result
  alias Harness.Run.RetryPolicy
  alias Harness.Run.TestDbIsolation
  alias Harness.Worktree
  alias Harness.Worktree.Isolation

  require Logger

  @github_auth_env_scrubs %{"GH_TOKEN" => false, "GITHUB_TOKEN" => false}
  @gh_config_dir Path.join([".harness", "gh-config"])
  @default_mem_threshold_kb 6 * 1024 * 1024
  @default_mem_sample_interval 5_000

  @type data :: map()
  # The first dispatch runs the task prompt fresh; an operator-steered resume
  # re-enters the agent's session with the steer prompt. There is no repair
  # loop — whatever the implementer leaves behind is the reviewer's to judge.
  @doc false
  @spec build_invocation(data()) :: Invocation.t()
  def build_invocation(%{operator_feedback: feedback} = data) when is_binary(feedback) do
    invocation(data, operator_steer_prompt(data), :resume)
  end

  def build_invocation(data) do
    invocation(data, data.item.prompt, nil)
  end

  @doc false
  @spec invocation(data(), String.t(), :resume | nil) :: Invocation.t()
  def invocation(data, prompt, session) do
    %Invocation{
      prompt: prompt,
      cwd: data.worktree.path,
      log_tag: data.item.id,
      session: session,
      model: data.requested_model,
      rule_content: agent_rule_content(data.project),
      permission_mode: :autonomous,
      adapter_opts: data.adapter_opts,
      env: in_run_env(data)
    }
  end

  @doc false
  @spec agent_rule_content(Project.t()) :: String.t()
  def agent_rule_content(%Project{languages: languages}), do: AgentRules.render_for_languages(languages)

  @doc false
  @spec run_env(Project.t(), String.t(), %{optional(String.t()) => String.t() | false}) :: %{
          optional(String.t()) => String.t() | false
        }
  def run_env(%Project{} = project, run_id, env) when is_map(env) and is_binary(run_id) do
    env
    |> scrub_github_auth_env()
    |> Map.merge(TestDbIsolation.env(project, run_id))
  end

  @doc false
  @spec in_run_env(data()) :: %{optional(String.t()) => String.t() | false}
  def in_run_env(%{env: env, worktree: %Worktree{path: path}}) do
    env
    |> Map.put("GH_CONFIG_DIR", Path.join(path, @gh_config_dir))
    |> Harness.RmapPath.ensure_agent_env()
  end

  @doc false
  @spec scrub_github_auth_env(%{optional(String.t()) => String.t() | false}) :: %{
          optional(String.t()) => String.t() | false
        }
  def scrub_github_auth_env(env) when is_map(env) do
    # Reach false positive triage: false is the Invocation env scrub payload,
    # not boolean membership. Task 25's Port env contract is %{var => value | false}.
    Map.merge(env, @github_auth_env_scrubs)
  end

  @doc false
  @spec teardown_test_database(data()) :: :ok
  def teardown_test_database(%{project: %Project{} = project, worktree: %Worktree{path: path}, run_id: run_id}) do
    TestDbIsolation.teardown(project, path, run_id)
  end

  def teardown_test_database(_data), do: :ok

  @doc false
  @spec tag_composed_input(AgentRun.t(), data()) :: AgentAdapter.composed_input()
  def tag_composed_input(%AgentRun{composed_input: input}, data) when is_map(input) do
    input
    |> Map.put(:attempt, length(data.composed_inputs))
    |> Map.put(:phase, composed_input_phase(input, data))
  end

  def tag_composed_input(%AgentRun{}, data) do
    %{
      executable: "",
      argv: [],
      rule_channel: data.adapter.rule_channel(),
      prompt: "",
      session: nil,
      rule_files: [],
      attempt: length(data.composed_inputs),
      phase: composed_input_phase_for_data(data)
    }
  end

  @doc false
  @spec composed_input_phase(AgentAdapter.composed_input(), data()) :: :initial | :steer
  def composed_input_phase(%{session: :resume}, _data), do: :steer

  def composed_input_phase(_input, data), do: composed_input_phase_for_data(data)

  @doc false
  @spec composed_input_phase_for_data(data()) :: :initial | :steer
  def composed_input_phase_for_data(%{operator_feedback: feedback}) when is_binary(feedback), do: :steer
  def composed_input_phase_for_data(_data), do: :initial

  @doc false
  @spec operator_steer_prompt(data()) :: String.t()
  def operator_steer_prompt(%{operator_feedback: feedback}) when is_binary(feedback) do
    """
    An operator has reviewed your progress and sent this guidance:

    #{feedback}
    """
  end

  @doc false
  @spec current_sha(data()) :: String.t()
  def current_sha(%{worktree: %Worktree{path: path, base_sha: fallback}}) do
    case Git.run(["rev-parse", "HEAD"], path) do
      {:ok, sha} -> non_empty_sha(String.trim(sha), fallback)
      {:error, _reason} -> fallback
    end
  end

  @doc false
  @spec non_empty_sha(String.t(), String.t()) :: String.t()
  def non_empty_sha("", fallback), do: fallback
  def non_empty_sha(sha, _fallback), do: sha

  # The message stamped on the agent's delivery commit — identifies the run and
  # the rmap task it served, so the commit is legible in `git log` after the
  # worktree it came from is gone.
  @doc false
  @spec commit_message(data()) :: String.t()
  def commit_message(data) do
    "harness: agent delivery — task #{data.item.id} #{data.item.title} (run #{data.run_id})"
  end

  @doc false
  @spec worktree_opts(data()) :: keyword()
  # An explicit :base_ref (e.g. a resumed run branching off the retained
  # harness/<old-run-id> branch) wins over the computed origin/<target> base.
  def worktree_opts(%{base_ref: base_ref} = data) when is_binary(base_ref) and base_ref != "" do
    Keyword.put(base_worktree_opts(data), :base_ref, base_ref)
  end

  def worktree_opts(%{project: %Project{target_branch: target}} = data) when is_binary(target) and target != "" do
    opts = base_worktree_opts(data)

    case fetch_target(data.project, target, data.substrate_retry) do
      :ok ->
        Keyword.put(opts, :base_ref, "origin/" <> target)

      {:error, reason} ->
        Logger.warning(
          "harness run: failed to fetch origin/#{target} for run #{data.run_id}: #{inspect(reason)}; falling back to HEAD"
        )

        opts
    end
  end

  def worktree_opts(data) do
    base_worktree_opts(data)
  end

  @doc false
  @spec base_worktree_opts(data()) :: keyword()
  def base_worktree_opts(data) do
    put_opt([id: data.run_id, substrate_retry: data.substrate_retry], :base_dir, data.base_dir)
  end

  @doc false
  @spec fetch_target(Project.t(), String.t(), keyword()) :: :ok | {:error, Git.error()}
  def fetch_target(%Project{} = project, target, substrate_retry) do
    case retry_substrate(substrate_retry, fn -> Git.run(["fetch", "origin", target], Project.repo_path(project)) end) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec run_driver(data(), module(), Invocation.t(), keyword()) :: {:ok, Outcome.t()} | {:error, term()}
  def run_driver(data, adapter, %Invocation{} = invocation, opts) do
    retry_substrate(data.substrate_retry, fn -> Driver.run(adapter, invocation, opts) end)
  end

  @doc false
  @spec retry_substrate(keyword(), (-> term())) :: term()
  def retry_substrate(opts, fun) when is_function(fun, 0) do
    RetryPolicy.retry(fun, RetryPolicy.new(opts))
  end

  @doc false
  @spec driver_opts(data(), pid()) :: keyword()
  def driver_opts(data, parent) do
    [
      on_spawn: fn run -> send(parent, {:run_handle, run}) end,
      on_output: fn chunk -> send(parent, {:transcript_chunk, chunk}) end
    ]
    |> put_opt(:total_timeout, data.total_timeout)
    |> put_opt(:idle_timeout, implementer_idle_timeout(data.idle_timeout))
    |> put_opt(:progress_timeout, data.progress_timeout)
  end

  @doc false
  @spec commit_worktree(data(), Worktree.t(), String.t()) ::
          {:ok, :committed | :no_changes, non_neg_integer()} | {:error, Worktree.error()}
  def commit_worktree(data, %Worktree{} = worktree, message) do
    retry_substrate(data.substrate_retry, fn ->
      with {:ok, diff_size} <- Worktree.diff_size(worktree),
           {:ok, status} <- Worktree.commit(worktree, message, substrate_retry: [max_retries: 0]) do
        {:ok, status, diff_size}
      end
    end)
  end

  @doc false
  @spec put_opt(keyword(), atom(), term()) :: keyword()
  def put_opt(opts, _key, nil), do: opts
  def put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @doc false
  @spec normalize_opts(nil | keyword() | map()) :: keyword()
  def normalize_opts(nil), do: []
  def normalize_opts(opts) when is_list(opts), do: opts
  def normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)

  @doc false
  @spec checkout_snapshot_for_run(data()) :: String.t() | nil
  def checkout_snapshot_for_run(%{checkout_pollution_check?: true} = data) do
    checkout_snapshot(Project.repo_path(data.project))
  end

  def checkout_snapshot_for_run(data) do
    if AgentAdapter.supports?(data.adapter, :worktree_isolation) do
      nil
    else
      checkout_snapshot(Project.repo_path(data.project))
    end
  end

  @doc false
  @spec checkout_snapshot(String.t()) :: String.t() | nil
  def checkout_snapshot(repo) when is_binary(repo) do
    case Isolation.snapshot(repo) do
      {:ok, snapshot} ->
        snapshot

      {:error, reason} ->
        Logger.warning("harness run: checkout snapshot failed for #{repo}: #{inspect(reason)}")
        nil
    end
  end

  @doc false
  @spec checkout_pollution_reason(data()) :: Result.reason() | nil
  def checkout_pollution_reason(data) do
    opts = [pollution_allowlist: data.pollution_allowlist]

    case Isolation.check_pollution(Project.repo_path(data.project), data.checkout_snapshot, opts) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  @doc false
  @spec worktree_isolation_limitation(module()) :: String.t() | nil
  def worktree_isolation_limitation(adapter) do
    if function_exported?(adapter, :worktree_isolation_limitation, 0) do
      adapter.worktree_isolation_limitation()
    end
  end

  @doc false
  @spec resolve_pollution_allowlist(Project.t(), keyword()) :: [String.t()]
  def resolve_pollution_allowlist(project, opts) do
    case Keyword.get(opts, :pollution_allowlist) do
      allowlist when is_list(allowlist) ->
        allowlist

      _ ->
        case project do
          %Project{pollution_allowlist: allowlist} when is_list(allowlist) -> allowlist
          _ -> Isolation.pollution_allowlist([])
        end
    end
  end

  @doc false
  @spec configured(atom(), term()) :: term()
  def configured(key, default) do
    :harness |> Application.get_env(:run, []) |> Keyword.get(key, default)
  end

  # Resolves a run timeout: explicit opt wins, else the `Harness.Config` schema
  # value (schema default folded with any persisted operator override). Keeps the
  # `||` fallbacks out of `init/1` so it stays under the complexity gate, and
  # routes the read through the schema (Task 167) — defaults live in `Config`, not
  # in `@default_*` attributes here.
  @doc false
  @spec run_timeout(keyword(), atom()) :: timeout() | nil
  def run_timeout(opts, key) do
    Keyword.get(opts, key) || Config.get({:run, key})
  end

  @doc false
  @spec requested_model(keyword(), Item.t(), module()) :: String.t() | nil
  def requested_model(opts, item, adapter) do
    if Keyword.has_key?(opts, :requested_model) do
      Keyword.fetch!(opts, :requested_model)
    else
      item.model || configured_model(adapter, item.agent)
    end
  end

  @doc false
  @spec configured_model(module(), atom()) :: String.t() | nil
  def configured_model(adapter, agent) do
    if adapter.capabilities().model_families == [], do: nil, else: Config.agent_model(agent)
  end

  # Resolves the per-run memory watchdog ceiling + sample interval (Task 200):
  # explicit opt > app env > module default. Kept out of `init/1`'s data map so
  # the `||` fallbacks don't push init over the cyclomatic-complexity gate.
  @doc false
  @spec mem_watchdog_config(keyword()) :: {pos_integer(), pos_integer()}
  def mem_watchdog_config(opts) do
    {Keyword.get(opts, :mem_threshold_kb) || configured(:mem_threshold_kb, @default_mem_threshold_kb),
     Keyword.get(opts, :mem_sample_interval) || configured(:mem_sample_interval, @default_mem_sample_interval)}
  end
end
