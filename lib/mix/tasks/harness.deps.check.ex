defmodule Mix.Tasks.Harness.Deps.Check do
  @shortdoc "Checks mix.exs for unjustified three-part optimistic dep constraints"

  @moduledoc """
  Fails when `mix.exs` contains a three-part optimistic dependency constraint
  like `~> 1.2.3` without a same-line comment explaining the tight pin.

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
      {:ok, violations} -> Mix.raise(message(path, violations))
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
    over-tight dependency constraints found:
    #{details}

    Use a two-part optimistic constraint like "~> x.y", or add a same-line
    comment explaining the real minor-bump breakage that requires a tight pin.
    """
  end
end
