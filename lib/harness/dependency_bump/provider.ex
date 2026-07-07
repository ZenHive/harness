defmodule Harness.DependencyBump.Provider do
  @moduledoc """
  Builds language-specific dependency-bump roadmap tasks from freshness facts.
  """

  alias Harness.DependencyBump.TaskSpec
  alias Harness.DepFreshness.Row

  @callback build(atom(), [Row.t()]) :: [TaskSpec.t()]
end
