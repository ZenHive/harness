defmodule Harness.ArchitectQA do
  @moduledoc """
  Mechanical Architect/QA handoff gate for post-landed waves.

  Harness does not judge whether the integrated base is good here. It only
  compares two persisted facts: the newest landed SHA for a project, and the SHA
  an orchestrator explicitly marked as Architect/QA-reviewed after running the
  full project gate on the landed base.
  """

  use Descripex, namespace: "/architect_qa"

  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Run.LogRecord
  alias Harness.SettingsStore

  @settings_key "architect_qa"
  @typedoc "Mechanical QA gate status for one project."
  @type status :: %{
          project_name: String.t(),
          required: boolean(),
          latest_landed_sha: String.t() | nil,
          last_reviewed_sha: String.t() | nil,
          reviewed_at: String.t() | nil,
          check_command: String.t() | nil,
          instructions: String.t()
        }

  api(
    :status,
    "Report whether a project has landed work that still needs the Architect/QA seat. Pure fact check: newest landed_sha vs last Architect/QA marker.",
    params: [
      project_name: [
        kind: :value,
        description: "Registered project name; resolved via Harness.ProjectRegistry.lookup/1."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{required, latest_landed_sha, last_reviewed_sha, reviewed_at, check_command, instructions}} or {:error, {:unknown_project, name}}."
    }
  )

  @spec status(String.t()) :: {:ok, status()} | {:error, {:unknown_project, String.t()} | term()}
  def status(project_name) when is_binary(project_name) do
    with {:ok, project} <- lookup_project(project_name) do
      status(project)
    end
  end

  @doc false
  @spec status(Project.t()) :: {:ok, status()} | {:error, term()}
  def status(%Project{} = project) do
    with {:ok, latest_sha} <- latest_landed_sha(project.name) do
      marker = marker_for(project.name)
      reviewed_sha = marker["sha"]

      {:ok,
       %{
         project_name: project.name,
         required: requires_review?(latest_sha, reviewed_sha),
         latest_landed_sha: latest_sha,
         last_reviewed_sha: reviewed_sha,
         reviewed_at: marker["reviewed_at"],
         check_command: full_gate(project),
         instructions: instructions(project)
       }}
    end
  end

  @doc false
  @spec ensure_current(Project.t()) :: :ok | {:error, {:architect_qa_required, status()} | term()}
  def ensure_current(%Project{} = project) do
    with {:ok, status} <- status(project) do
      if status.required, do: {:error, {:architect_qa_required, status}}, else: :ok
    end
  end

  api(
    :mark_done,
    "Mark Architect/QA complete for a project. Call only after running the full landed-base gate and making/fixing any whole-surface findings. If sha is omitted, marks the newest landed SHA.",
    params: [
      project_name: [
        kind: :value,
        description: "Registered project name; resolved via Harness.ProjectRegistry.lookup/1."
      ],
      sha: [
        kind: :value,
        default: nil,
        description:
          "Landed commit SHA that Architect/QA reviewed. Omit/null to mark the newest landed SHA currently in ResultStore."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, status} after persisting the marker, {:error, :no_landed_sha} when no landed run exists, or {:error, {:unknown_project, name}}."
    }
  )

  @spec mark_done(String.t(), String.t() | nil) ::
          {:ok, status()} | {:error, :no_landed_sha | {:unknown_project, String.t()} | term()}
  def mark_done(project_name, sha \\ nil) when is_binary(project_name) and (is_binary(sha) or is_nil(sha)) do
    with {:ok, project} <- lookup_project(project_name),
         {:ok, landed_sha} <- reviewed_sha(project.name, sha),
         :ok <- persist_marker(project.name, landed_sha) do
      status(project)
    end
  end

  @spec reviewed_sha(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, :no_landed_sha | term()}
  defp reviewed_sha(_project_name, sha) when is_binary(sha) and sha != "", do: {:ok, sha}

  defp reviewed_sha(project_name, _sha) do
    case latest_landed_sha(project_name) do
      {:ok, sha} when is_binary(sha) -> {:ok, sha}
      {:ok, nil} -> {:error, :no_landed_sha}
      {:error, _reason} = error -> error
    end
  end

  @spec latest_landed_sha(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  defp latest_landed_sha(project_name) do
    case ResultStore.list_run_records(project_name: project_name) do
      {:ok, records} -> {:ok, Enum.find_value(records, &landed_sha/1)}
      {:error, _reason} = error -> error
    end
  end

  @spec landed_sha(LogRecord.t()) :: String.t() | nil
  defp landed_sha(%LogRecord{landed_sha: sha}) when is_binary(sha) and sha != "", do: sha
  defp landed_sha(%LogRecord{}), do: nil

  @spec marker_for(String.t()) :: map()
  defp marker_for(project_name) do
    @settings_key
    |> SettingsStore.fetch_map()
    |> Map.get(project_name, %{})
  end

  @spec persist_marker(String.t(), String.t()) :: :ok | {:error, term()}
  defp persist_marker(project_name, sha) do
    markers =
      @settings_key
      |> SettingsStore.fetch_map()
      |> Map.put(project_name, %{
        "sha" => sha,
        "reviewed_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    SettingsStore.put(@settings_key, markers)
  end

  @spec requires_review?(String.t() | nil, String.t() | nil) :: boolean()
  defp requires_review?(nil, _reviewed_sha), do: false
  defp requires_review?(latest_sha, reviewed_sha), do: latest_sha != reviewed_sha

  @spec full_gate(Project.t()) :: String.t()
  defp full_gate(%Project{check_command: "mix check.dispatch"}), do: "mix precommit.full"
  defp full_gate(%Project{check_command: nil}), do: "project full Architect/QA gate"
  defp full_gate(%Project{check_command: command}), do: command

  @spec instructions(Project.t()) :: String.t()
  defp instructions(%Project{} = project) do
    "Run #{full_gate(project)} on the landed base, review the integrated surface against roadmap intent/domain invariants, fix findings, then call architect_qa-mark_done."
  end

  @spec lookup_project(String.t()) :: {:ok, Project.t()} | {:error, {:unknown_project, String.t()}}
  defp lookup_project(project_name) do
    case ProjectRegistry.lookup(project_name) do
      {:ok, %Project{} = project} -> {:ok, project}
      {:error, _reason} -> {:error, {:unknown_project, project_name}}
    end
  end
end
