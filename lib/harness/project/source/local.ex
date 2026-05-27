defmodule Harness.Project.Source.Local do
  @moduledoc """
  The local-path variant of `t:Harness.Project.source/0`.

  Represented on the project struct as the tagged tuple `{:local, path}`. The
  path is taken as-is — harness assumes the working tree already exists at
  `path` and is a git repository.
  """

  alias Harness.Project

  @typedoc "The tagged tuple form stored on `%Harness.Project{}.source`."
  @type t :: {:local, String.t()}

  @doc """
  Returns the expanded local working-tree path for a `{:local, _}` project.
  """
  @spec path(Project.t()) :: String.t()
  def path(%Project{source: {:local, path}}) when is_binary(path), do: Path.expand(path)
end
