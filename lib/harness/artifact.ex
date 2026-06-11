defmodule Harness.Artifact do
  @moduledoc """
  Mechanical filesystem read of an agent-written artifact.

  Agents in the gate workflow communicate through JSON artifact files inside
  their working directory (`.harness/review.json`, `.harness/recovery.json`,
  `.harness/cron-plan.json`, the audit report). This is the shared read step:
  it maps the filesystem outcomes every reader distinguishes — `:enoent` means
  the agent never wrote the file, any other read error means the file is
  unusable — and leaves all interpretation of the contents to the caller.
  """

  @doc """
  Reads the artifact at `relative_path` under `root`.

  Returns `{:error, :missing}` when the file does not exist, and
  `{:error, {:malformed, {:unreadable, reason}}}` for any other read failure.
  """
  @spec read(String.t(), String.t()) ::
          {:ok, binary()} | {:error, :missing | {:malformed, {:unreadable, term()}}}
  # sobelow_skip ["Traversal.FileModule"]
  # root is harness-generated (run worktree / scratch dir), never user input.
  def read(root, relative_path) when is_binary(root) and is_binary(relative_path) do
    case File.read(Path.join(root, relative_path)) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:error, :missing}
      {:error, reason} -> {:error, {:malformed, {:unreadable, reason}}}
    end
  end
end
