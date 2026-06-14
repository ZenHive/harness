defmodule Harness.Roadmap.MisMarkAudit do
  @moduledoc """
  Flags mechanically suspicious landed roadmap rows.

  A `done` task with `shipped_in` should point at a commit that touched at least
  one of the task's declared `files_to_modify`. No overlap is not proof of a bad
  task, but it is the exact ledger-smell produced when lander writeback marks a
  reassigned numeric id.
  """

  alias Harness.Git

  @type finding :: %{
          id: String.t(),
          title: String.t() | nil,
          shipped_in: String.t(),
          files_to_modify: [String.t()],
          changed_files: [String.t()]
        }

  @doc "Returns done-task rows whose shipped commit touches none of files_to_modify."
  @spec flagged([map()], String.t()) :: {:ok, [finding()]} | {:error, term()}
  def flagged(tasks, repo) when is_list(tasks) and is_binary(repo) do
    tasks
    |> Enum.filter(&auditable?/1)
    |> Enum.reduce_while({:ok, []}, fn task, {:ok, acc} ->
      case changed_files(repo, task["shipped_in"]) do
        {:ok, files} -> {:cont, {:ok, maybe_flag(task, files, acc)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, findings} -> {:ok, Enum.reverse(findings)}
      {:error, _reason} = error -> error
    end
  end

  @spec auditable?(map()) :: boolean()
  defp auditable?(%{"status" => "done", "shipped_in" => sha, "files_to_modify" => files})
       when is_binary(sha) and sha != "" and is_list(files) do
    files != []
  end

  defp auditable?(_task), do: false

  @spec changed_files(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  defp changed_files(repo, sha) do
    case Git.run(["diff-tree", "--no-commit-id", "--name-only", "-r", sha], repo) do
      {:ok, output} -> {:ok, String.split(output, "\n", trim: true)}
      {:error, reason} -> {:error, {:changed_files_failed, sha, reason}}
    end
  end

  @spec maybe_flag(map(), [String.t()], [finding()]) :: [finding()]
  defp maybe_flag(task, changed_files, acc) do
    files = Enum.filter(task["files_to_modify"], &is_binary/1)

    if MapSet.disjoint?(MapSet.new(files), MapSet.new(changed_files)) do
      [finding(task, files, changed_files) | acc]
    else
      acc
    end
  end

  @spec finding(map(), [String.t()], [String.t()]) :: finding()
  defp finding(task, files, changed_files) do
    %{
      id: to_string(task["id"]),
      title: task["title"],
      shipped_in: task["shipped_in"],
      files_to_modify: files,
      changed_files: changed_files
    }
  end
end
