defmodule Mix.Tasks.Harness.Projects.UseDispatchCheck do
  @shortdoc "Points registered Elixir projects at mix check.dispatch"

  @moduledoc """
  Updates registered Elixir project check hints to the dispatch gate.

      mix harness.projects.use_dispatch_check

  This mutates the harness project registry only. It does not edit consumer
  repositories; projects missing `mix check.dispatch` should fail loudly on
  dispatch so the missing alias is fixed in that repo.
  """

  use Mix.Task

  alias Harness.Project
  alias Harness.ProjectRegistry

  @dispatch_check_command "mix check.dispatch"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    disable_standalone_dashboard()
    Mix.Task.run("app.start")

    ProjectRegistry.list()
    |> Enum.reduce(%{updated: [], unchanged: [], skipped: []}, &update_project/2)
    |> print_summary()
  end

  @spec update_project(Project.t(), map()) :: map()
  defp update_project(%Project{} = project, acc) do
    cond do
      :elixir not in project.languages ->
        Map.update!(acc, :skipped, &[project.name | &1])

      project.check_command == @dispatch_check_command ->
        Map.update!(acc, :unchanged, &[project.name | &1])

      true ->
        :ok = ProjectRegistry.upsert(%{project | check_command: @dispatch_check_command})
        Map.update!(acc, :updated, &[project.name | &1])
    end
  end

  @spec disable_standalone_dashboard() :: :ok
  defp disable_standalone_dashboard do
    dashboard_config = Application.get_env(:harness, :dashboard, [])
    Application.put_env(:harness, :dashboard, Keyword.put(dashboard_config, :enabled, false))
  end

  @spec print_summary(map()) :: :ok
  defp print_summary(summary) do
    Mix.shell().info("Updated Elixir projects: #{names(summary.updated)}")
    Mix.shell().info("Already on dispatch check: #{names(summary.unchanged)}")
    Mix.shell().info("Skipped non-Elixir projects: #{names(summary.skipped)}")
    :ok
  end

  @spec names([String.t()]) :: String.t()
  defp names([]), do: "none"

  defp names(names) do
    names
    |> Enum.reverse()
    |> Enum.join(", ")
  end
end
