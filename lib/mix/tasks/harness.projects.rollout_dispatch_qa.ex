defmodule Mix.Tasks.Harness.Projects.RolloutDispatchQa do
  @shortdoc "Idempotent focused-dispatch + audit-QA rollout (dry-run by default)"

  @moduledoc """
  Operator-invoked rollout of focused dispatch checks and post-merge audit QA.

      mix harness.projects.rollout_dispatch_qa
      mix harness.projects.rollout_dispatch_qa --apply
      mix harness.projects.rollout_dispatch_qa --apply --name aave_sim

  Dry-run (default) inventories live settings, writes a prior-settings capture,
  and prints the plan. `--apply` installs `qa_command` without reducing
  `check_command`. Dispatch switches only after an evidenced complete QA pass.
  Failed upserts restore captured prior check/qa commands.

  This mutates the harness project registry only. Consumer repositories are not
  edited; their write-sets are printed for the orchestrator.
  """

  use Mix.Task

  alias Harness.Projects.DispatchQA

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [apply: :boolean, name: :keep, "capture-dir": :string]
      )

    if positional != [] or invalid != [], do: Mix.raise("Unknown rollout arguments: #{inspect(positional ++ invalid)}")
    disable_standalone_dashboard()
    Mix.Task.run("app.start")

    rollout(opts)
  end

  @spec rollout(keyword()) :: :ok
  defp rollout(opts) do
    names = opts |> Keyword.get_values(:name) |> List.flatten()

    activate_opts =
      [apply: Keyword.get(opts, :apply, false)]
      |> maybe_put(:names, names)
      |> maybe_put(:capture_dir, Keyword.get(opts, :"capture-dir"))

    case DispatchQA.activate(activate_opts) do
      {:ok, result} ->
        print_rollout(result)

      {:error, %{projects: _} = result} ->
        print_rollout(result)
        Mix.raise("dispatch-qa rollout failed; inspect #{result.capture_path}.result.json")

      {:error, reason} ->
        Mix.raise("dispatch-qa rollout failed: #{inspect(reason)}")
    end
  end

  @spec print_rollout(map()) :: :ok
  defp print_rollout(result) do
    Mix.shell().info("Applied: #{result.applied?}")
    Mix.shell().info("Capture: #{result.capture_path}")

    Enum.each(result.projects, fn project ->
      Mix.shell().info(
        "#{project.name}: #{project.status} check=#{inspect(get_in(project, [:readback, :check_command]))} qa=#{inspect(get_in(project, [:readback, :qa_command]))}#{reason_suffix(project.reason)} write_set=#{Enum.join(project.write_set, ",")}"
      )
    end)

    :ok
  end

  @spec reason_suffix(String.t() | nil) :: String.t()
  defp reason_suffix(nil), do: ""
  defp reason_suffix(reason), do: " (#{reason})"

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @spec disable_standalone_dashboard() :: :ok
  defp disable_standalone_dashboard do
    dashboard_config = Application.get_env(:harness, :dashboard, [])
    Application.put_env(:harness, :dashboard, Keyword.put(dashboard_config, :enabled, false))
  end
end
