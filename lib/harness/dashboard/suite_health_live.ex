defmodule Harness.Dashboard.SuiteHealthLive do
  @moduledoc """
  Per-project full-suite health-check witness panel (`/harness/health`).

  Displays raw pass/fail facts, failing tests, exit codes, and timestamps.
  Harness counts and renders only — never classifies flakes or gates dispatch.
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Dashboard.ProjectSelection
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.SuiteHealth
  alias Harness.SuiteHealth.Result
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @tick_interval_ms 30_000

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_tick()

    projects = ProjectRegistry.list()

    {:ok,
     socket
     |> assign(:projects, projects)
     |> assign(:results, results_by_project(projects))}
  end

  @impl Phoenix.LiveView
  @spec handle_params(map(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_params(params, _uri, socket) do
    ProjectSelection.handle_params(params, socket)
  end

  @impl Phoenix.LiveView
  @spec handle_info(:health_tick, Socket.t()) :: {:noreply, Socket.t()}
  def handle_info(:health_tick, socket) do
    schedule_tick()
    projects = ProjectRegistry.list()

    {:noreply,
     socket
     |> assign(:projects, projects)
     |> assign(:results, results_by_project(projects))}
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("select_project", %{"project" => name}, socket) do
    {:noreply, push_patch(socket, to: "/harness/health/#{name}")}
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="topbar">
      <strong>Suite health</strong>
      <span class="count">{length(@projects)} projects</span>
      <a href="/harness">← All runs</a>
    </div>

    <p :if={@projects == []}>No projects registered.</p>

    <form :if={@projects != []} id="suite-health-form">
      <label for="suite-health-select">Project</label>
      <select
        id="suite-health-select"
        name="project"
        phx-change="select_project"
        value={@selected_project}
      >
        <option
          :for={project <- @projects}
          value={project.name}
          selected={project.name == @selected_project}
        >
          {project.name}
        </option>
      </select>
    </form>

    <section :if={@projects != []} id="suite-health-panel">
      <.project_panel
        project={ProjectSelection.selected_project(@projects, @selected_project)}
        result={Map.get(@results, @selected_project)}
      />
    </section>
    """
  end

  attr(:project, Project, required: true)
  attr(:result, Result, default: nil)

  @spec project_panel(map()) :: Rendered.t()
  defp project_panel(%{result: nil} = assigns) do
    ~H"""
    <div class="empty-state" id="suite-health-empty">
      <strong>No health-check facts yet</strong>
      <p>
        {@project.name} has not been checked. The daily suite-health cron records raw
        full-suite results (including integration tests) when it next runs.
      </p>
    </div>
    """
  end

  defp project_panel(%{result: %Result{skip_reason: reason}} = assigns) when is_binary(reason) do
    ~H"""
    <p class="count" id="suite-health-summary">
      Skipped · last checked {ProjectSelection.format_checked_at(@result.checked_at)} · {@result.languages}
    </p>
    <p id="suite-health-skip-reason"><code>{@result.skip_reason}</code></p>
    """
  end

  defp project_panel(assigns) do
    ~H"""
    <p class="count" id="suite-health-summary">
      {pass_label(@result.passed)} · exit {@result.exit_code} · last checked {ProjectSelection.format_checked_at(
        @result.checked_at
      )} · {@result.languages}
    </p>

    <p :if={@result.command} id="suite-health-command">
      Command: <code>{@result.command}</code>
    </p>

    <p :if={@result.base_sha} id="suite-health-base">
      Base SHA: <code>{@result.base_sha}</code>
    </p>

    <section :if={@result.failing_tests != []} id="suite-health-failures">
      <h3>Failing tests</h3>
      <ul>
        <li :for={failure <- @result.failing_tests}>
          <code>{failure_label(failure)}</code>
        </li>
      </ul>
    </section>

    <p :if={@result.passed == false and @result.failing_tests == []} id="suite-health-red-no-list">
      Red with no parsed failing-test identifiers — see the recorded exit code.
    </p>
    """
  end

  @spec schedule_tick() :: reference()
  defp schedule_tick, do: Process.send_after(self(), :health_tick, @tick_interval_ms)

  @spec results_by_project([Project.t()]) :: %{String.t() => Result.t()}
  defp results_by_project(projects) do
    case SuiteHealth.list_results() do
      {:ok, results} ->
        results
        |> Map.new(&{&1.project_name, &1})
        |> Map.take(Enum.map(projects, & &1.name))

      {:error, _reason} ->
        %{}
    end
  end

  @spec pass_label(boolean() | nil) :: String.t()
  defp pass_label(true), do: "Passed"
  defp pass_label(false), do: "Failed"
  defp pass_label(nil), do: "Skipped"

  @spec failure_label(map()) :: String.t()
  defp failure_label(%{"name" => name} = failure) do
    file = Map.get(failure, "file")
    line = Map.get(failure, "line")
    failure_label(%{name: name, file: file, line: line})
  end

  defp failure_label(%{name: name} = failure) do
    case {Map.get(failure, :file), Map.get(failure, :line)} do
      {file, line} when is_binary(file) and is_integer(line) -> "#{name} (#{file}:#{line})"
      {file, _} when is_binary(file) -> "#{name} (#{file})"
      _ -> name
    end
  end
end
