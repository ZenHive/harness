defmodule Harness.InRepoTemplate do
  @moduledoc """
  Canonical in-repo `harness/` subdirectory template under
  `priv/templates/in_repo_harness/`.

  Used by docs, tests, and (future) `mix harness.init --in-repo`.
  """

  @spec dir() :: String.t()
  def dir, do: Path.join(:code.priv_dir(:harness), "templates/in_repo_harness")

  @doc """
  Recursively copies the template into `dest_harness_dir` (the `harness/` path).
  """
  @spec copy!(String.t()) :: :ok
  def copy!(dest_harness_dir) when is_binary(dest_harness_dir) do
    File.cp_r!(dir(), dest_harness_dir)
    :ok
  end
end
