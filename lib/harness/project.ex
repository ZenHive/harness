defmodule Harness.Project do
  @moduledoc """
  A registered orchestration target: source repo, verification stack, roadmap,
  and optional per-project concurrency cap.

  - `name` — unique slug; worktrees are rooted at `<base_dir>/<name>/<run-id>`.
  - `source` — where the repo lives today (`{:local, path}`; GitHub lands in Task 47).
  - `check_stack` — the `%Harness.CheckStack{}` grading runs against.
  - `roadmap_path` — project root holding `roadmap/tasks.toml` for rmap ingestion.
  - `concurrency_cap` — per-project batch cap; `nil` inherits the global default.
  """

  alias Harness.CheckStack

  @enforce_keys [:name, :source, :check_stack, :roadmap_path]
  defstruct [:name, :source, :check_stack, :roadmap_path, concurrency_cap: nil]

  @typedoc "Where harness finds the target repository."
  @type source :: {:local, String.t()}

  @typedoc "A first-class orchestration target."
  @type t :: %__MODULE__{
          name: String.t(),
          source: source(),
          check_stack: CheckStack.t(),
          roadmap_path: String.t(),
          concurrency_cap: pos_integer() | nil
        }

  @doc """
  Returns the expanded local repository path for `project`'s source.
  """
  @spec repo_path(t()) :: String.t()
  def repo_path(%__MODULE__{source: {:local, path}}) when is_binary(path), do: Path.expand(path)
end
