defmodule Mix.Tasks.Harness.Deps.Check do
  @shortdoc "Warns about undocumented three-part optimistic dep constraints"

  @moduledoc """
  Warns when `mix.exs` contains a three-part optimistic dependency constraint
  like `~> 1.2.3` without a same-line comment explaining the tight pin.
  Dependency constraints are advisory; unreadable files still fail.

      mix harness.deps.check
  """

  use Mix.Task

  alias Harness.DependencyConstraintGuard

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    path = List.first(args) || "mix.exs"

    case DependencyConstraintGuard.violations(path) do
      {:ok, []} -> :ok
      {:ok, violations} -> Mix.shell().info(message(path, violations))
      {:error, reason} -> Mix.raise("could not read #{path}: #{inspect(reason)}")
    end
  end

  @spec message(String.t(), [DependencyConstraintGuard.violation()]) :: String.t()
  defp message(path, violations) do
    details =
      Enum.map_join(violations, "\n", fn violation ->
        "  #{path}:#{violation.line}: #{violation.constraint} in #{violation.text}"
      end)

    """
    warning: narrow dependency constraints found (advisory):
    #{details}

    These constraints allow patch updates only. Consider whether minor updates
    should also be allowed, or document why the narrower range is intentional.
    """
  end
end
