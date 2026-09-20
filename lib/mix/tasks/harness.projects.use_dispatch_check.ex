defmodule Mix.Tasks.Harness.Projects.UseDispatchCheck do
  @shortdoc "Retired unchecked settings migration"
  @moduledoc "Use harness.projects.rollout_dispatch_qa for captured, QA-evidenced changes."
  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: no_return()
  def run(_args) do
    Mix.raise(
      "Unchecked dispatch migration is retired. Use mix harness.projects.rollout_dispatch_qa (dry-run), then --apply after inspecting the capture and QA evidence."
    )
  end
end
