defmodule Harness.Autonomy do
  @moduledoc """
  Read-only operator surface for cron autonomy state.

  Reports the persisted master switch, schedule, presets, and per-project
  autonomy facts. It delegates to `Harness.Cron.Settings` and
  `Harness.ProjectRegistry`; it does not make dispatch decisions.
  """

  use Descripex, namespace: "/autonomy"

  alias Harness.Cron.Settings
  alias Harness.Project
  alias Harness.ProjectRegistry

  @typedoc "JSON-safe cron autonomy status."
  @type status :: %{
          master_enabled: boolean(),
          schedule: String.t(),
          active_preset: String.t() | nil,
          schedule_presets: [map()],
          projects: [map()]
        }

  api(:status, "Return cron autonomy switches, schedule, presets, and per-project effective state.",
    returns: %{
      type: :map,
      description:
        "%{master_enabled, schedule, active_preset, schedule_presets, projects: [%{name, enabled, dispatch_mode, effective}]}"
    }
  )

  @spec status() :: status()
  def status do
    %{
      master_enabled: Settings.master_enabled?(),
      schedule: Settings.schedule(),
      active_preset: Settings.active_preset(),
      schedule_presets: schedule_presets(),
      projects: Enum.map(ProjectRegistry.list(), &project_status/1)
    }
  end

  @spec schedule_presets() :: [map()]
  defp schedule_presets do
    Enum.map(Settings.schedule_presets(), fn {key, label, crontab} ->
      %{key: key, label: label, crontab: crontab}
    end)
  end

  @spec project_status(Project.t()) :: map()
  defp project_status(%Project{name: name} = project) do
    %{
      name: name,
      enabled: Settings.project_enabled?(project),
      dispatch_mode: project |> Settings.dispatch_mode() |> Atom.to_string(),
      effective: Settings.effective?(project)
    }
  end
end
