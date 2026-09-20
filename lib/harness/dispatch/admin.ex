defmodule Harness.Dispatch.Admin do
  @moduledoc "Project registration and manual cron approval administration."

  alias Harness.Cron.PendingDispatch
  alias Harness.Dispatch.Presentation
  alias Harness.Project
  alias Harness.ProjectRegistry

  @spec pending(String.t() | nil) :: {:ok, %{pending: [map()]}}
  @doc false
  def pending(project_name \\ nil) when is_nil(project_name) or is_binary(project_name) do
    records =
      PendingDispatch.list()
      |> filter_pending(project_name)
      |> Enum.map(&Presentation.summarize_pending/1)

    {:ok, %{pending: records}}
  end

  @spec approve(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  @doc false
  def approve(pending_id) when is_binary(pending_id), do: approve(pending_id, nil)

  @spec approve(String.t(), DateTime.t() | nil) :: {:ok, map()} | {:error, term()}
  @doc false
  def approve(pending_id, parked_at) when is_binary(pending_id) do
    case PendingDispatch.approve(pending_id, parked_at) do
      {:ok, %{adapter: adapter} = result} -> {:ok, %{result | adapter: inspect(adapter)}}
      {:error, _reason} = error -> error
    end
  end

  # JSON-native scalar params map 1:1 onto apply/3; this 9th optional field
  # is the same tool, not a new knob family.
  @spec register_project(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          nonempty_list(atom() | String.t()),
          String.t() | nil,
          pos_integer() | nil,
          [String.t()],
          String.t() | nil
        ) ::
          {:ok, %{name: String.t()}} | {:error, term()}

  @doc false
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  def register_project(
        name,
        source_type,
        source_location,
        roadmap_path,
        languages,
        check_command \\ nil,
        concurrency_cap \\ nil,
        warm_paths \\ [],
        roadmap_target_branch \\ nil
      )
      when is_binary(name) and is_binary(source_type) and is_binary(source_location) and is_binary(roadmap_path) do
    with {:ok, source} <- build_source(source_type, source_location),
         attrs = [
           name: name,
           source: source,
           roadmap_path: roadmap_path,
           check_command: check_command,
           concurrency_cap: concurrency_cap,
           languages: languages,
           warm_paths: warm_paths,
           roadmap_target_branch: normalize_roadmap_target_branch(roadmap_target_branch)
         ],
         :ok <- ProjectRegistry.register(attrs) do
      {:ok, %{name: name}}
    end
  end

  @spec build_source(String.t(), String.t()) ::
          {:ok, Project.source()} | {:error, {:invalid_source_type, String.t()}}
  defp build_source("local", location), do: {:ok, {:local, location}}

  defp build_source("github", location), do: {:ok, {:github, location}}

  defp build_source(other, _location), do: {:error, {:invalid_source_type, other}}

  @spec normalize_roadmap_target_branch(term()) :: term()
  defp normalize_roadmap_target_branch(branch) when is_binary(branch) do
    case String.trim(branch) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_roadmap_target_branch(other), do: other

  @spec filter_pending([PendingDispatch.t()], String.t() | nil) :: [PendingDispatch.t()]
  defp filter_pending(records, nil), do: records

  defp filter_pending(records, project_name), do: Enum.filter(records, &(&1.project_name == project_name))
end
