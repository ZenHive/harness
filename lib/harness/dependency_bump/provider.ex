defmodule Harness.DependencyBump.Provider do
  @moduledoc """
  Builds language-specific dependency-bump roadmap tasks from freshness facts.

  `use Harness.DependencyBump.Provider, check_command: "...", files_to_modify: [...]`
  injects the uniform `build/2` callback and sets `@check_command` / `@files_to_modify`,
  which the module's own `body/2` also interpolates. Each module supplies only its
  per-language `body/2`, `acceptance_criteria/1`, and the two values above.
  """

  alias Harness.DependencyBump.TaskSpec
  alias Harness.DepFreshness.Row

  @callback build(atom(), [Row.t()]) :: [TaskSpec.t()]

  @doc false
  defmacro __using__(opts) do
    check_command = Keyword.fetch!(opts, :check_command)
    files_to_modify = Keyword.fetch!(opts, :files_to_modify)

    quote do
      @behaviour Harness.DependencyBump.Provider

      alias Harness.DependencyBump.Provider.Common
      alias Harness.DepFreshness.Row

      @check_command unquote(check_command)
      @files_to_modify unquote(files_to_modify)

      @impl Harness.DependencyBump.Provider
      @spec build(atom(), [Row.t()]) :: [Harness.DependencyBump.TaskSpec.t()]
      def build(language, rows) when is_atom(language) and is_list(rows) do
        Common.specs(language, rows,
          title: & &1,
          body: &body/2,
          acceptance_criteria: &acceptance_criteria/1,
          files_to_modify: @files_to_modify,
          check_command: @check_command
        )
      end
    end
  end
end
