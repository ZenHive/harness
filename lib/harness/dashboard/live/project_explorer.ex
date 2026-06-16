defmodule Harness.Dashboard.Live.ProjectExplorer do
  @moduledoc """
  Read-only dashboard explorer for registered Elixir project structure.

  The view displays structural facts returned by `Harness.CodeSearch`: modules,
  defs/defps, and caller/callee edges. It does not score, rank, or interpret
  those facts.
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.CodeSearch
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @definition_limit 500
  @edge_limit 100

  @typep edge_kind :: :callers | :callees
  @typep empty_state :: :no_projects | :unknown_project | :unsupported_language | :code_search_unavailable
  @typep explorer_state ::
           :ready | :no_projects | :unknown_project | :unsupported_language | :code_search_unavailable

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Socket.t()) ::
          {:ok, Socket.t()}
  def mount(%{"name" => name}, _session, socket) do
    projects = ProjectRegistry.list()

    {:ok,
     socket
     |> assign(:projects, projects)
     |> assign(:selected_symbol, nil)
     |> assign(:callers, [])
     |> assign(:callees, [])
     |> load_project(name, projects)}
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Socket.t()) ::
          {:noreply, Socket.t()}
  def handle_event("select_project", %{"project" => name}, socket) do
    {:noreply,
     socket
     |> assign(:selected_symbol, nil)
     |> assign(:callers, [])
     |> assign(:callees, [])
     |> load_project(name, socket.assigns.projects)}
  end

  def handle_event("select_symbol", %{"symbol" => symbol}, socket) do
    project = socket.assigns.project

    callers = edge_facts(:callers, project.name, symbol)
    callees = edge_facts(:callees, project.name, symbol)

    {:noreply,
     socket
     |> assign(:selected_symbol, symbol)
     |> assign(:callers, callers)
     |> assign(:callees, callees)}
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="topbar">
      <strong>Project explorer</strong>
      <span class="count">{length(@projects)} projects</span>
      <a href="/harness">Back to all runs</a>
    </div>

    <form :if={@projects != []} id="project-explorer-form">
      <label for="project-explorer-select">Project</label>
      <select
        id="project-explorer-select"
        name="project"
        phx-change="select_project"
        value={project_name(@project)}
      >
        <option
          :for={project <- @projects}
          value={project.name}
          selected={selected_project?(@project, project)}
        >
          {project.name}
        </option>
      </select>
    </form>

    <div :if={@state != :ready} class="empty-state" id="project-explorer-empty">
      <strong>{empty_title(@state)}</strong>
      <p>{empty_message(@state, @project, @reason)}</p>
    </div>

    <section :if={@state == :ready} id="project-explorer">
      <p class="count">
        {map_size(@modules)} modules - {length(@definitions)} defs
      </p>

      <table id="project-explorer-modules">
        <thead>
          <tr>
            <th>Module</th>
            <th>Definitions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{module, definitions} <- @modules}>
            <td><code>{module}</code></td>
            <td>
              <button
                :for={definition <- definitions}
                type="button"
                class="facet-pill"
                phx-click="select_symbol"
                phx-value-symbol={symbol(definition)}
              >
                <span>{kind_label(definition)}</span>
                <code>{definition_label(definition)}</code>
              </button>
              <span :if={definitions == []} class="count">No defs found.</span>
            </td>
          </tr>
        </tbody>
      </table>

      <section :if={@selected_symbol} id="project-explorer-symbol">
        <h2>Selected symbol</h2>
        <p><code>{@selected_symbol}</code></p>

        <div class="table-scroll">
          <h3>Callers</h3>
          <p :if={@callers == []} class="count">No callers found.</p>
          <.edge_table
            :if={@callers != []}
            id="project-explorer-callers"
            facts={@callers}
            side={:caller}
          />

          <h3>Callees</h3>
          <p :if={@callees == []} class="count">No callees found.</p>
          <.edge_table
            :if={@callees != []}
            id="project-explorer-callees"
            facts={@callees}
            side={:callee}
          />
        </div>
      </section>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:facts, :list, required: true)
  attr(:side, :atom, values: [:caller, :callee], required: true)

  @spec edge_table(map()) :: Rendered.t()
  defp edge_table(assigns) do
    ~H"""
    <table id={@id}>
      <thead>
        <tr>
          <th>Symbol</th>
          <th>Edge</th>
          <th>Location</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={fact <- @facts}>
          <td><code>{edge_symbol(fact, @side)}</code></td>
          <td><code>{edge_pair(fact)}</code></td>
          <td><code>{location(fact)}</code></td>
        </tr>
      </tbody>
    </table>
    """
  end

  @spec load_project(Socket.t(), String.t(), [Project.t()]) :: Socket.t()
  defp load_project(socket, _name, []), do: empty(socket, :no_projects, nil, nil)

  defp load_project(socket, name, projects) do
    case Enum.find(projects, &(&1.name == name)) do
      %Project{language: language} = project when language in [nil, :elixir] ->
        load_elixir_project(socket, project)

      %Project{} = project ->
        empty(socket, :unsupported_language, project, {:unsupported_language, project.language})

      nil ->
        empty(socket, :unknown_project, nil, {:unknown_project, name})
    end
  end

  @spec load_elixir_project(Socket.t(), Project.t()) :: Socket.t()
  defp load_elixir_project(socket, project) do
    case definitions(project.name) do
      {:ok, %{status: :skipped, reason: reason}} ->
        empty(socket, :code_search_unavailable, project, reason)

      {:ok, %{facts: facts}} ->
        socket
        |> assign(:project, project)
        |> assign(:state, :ready)
        |> assign(:reason, nil)
        |> assign(:definitions, definition_facts(facts))
        |> assign(:modules, modules(facts))

      {:error, reason} ->
        empty(socket, :code_search_unavailable, project, reason)
    end
  end

  @spec empty(Socket.t(), explorer_state(), Project.t() | nil, term()) ::
          Socket.t()
  defp empty(socket, state, project, reason) do
    socket
    |> assign(:project, project)
    |> assign(:state, state)
    |> assign(:reason, reason)
    |> assign(:definitions, [])
    |> assign(:modules, %{})
  end

  @spec definitions(String.t()) :: CodeSearch.result()
  defp definitions(project_name) do
    call_search(:definitions, project_name, "", limit: @definition_limit)
  end

  @spec edge_facts(edge_kind(), String.t(), String.t()) :: [CodeSearch.fact()]
  defp edge_facts(kind, project_name, symbol_name) do
    case call_search(kind, project_name, symbol_name, limit: @edge_limit) do
      {:ok, %{facts: facts}} -> facts
      _other -> []
    end
  end

  @spec call_search(edge_kind() | :definitions, String.t(), String.t(), keyword()) :: CodeSearch.result()
  defp call_search(kind, project_name, query, opts) do
    case Application.get_env(:harness, :dashboard_code_search) do
      fun when is_function(fun, 4) -> fun.(kind, project_name, query, opts)
      _other -> apply(CodeSearch, kind, [project_name, query, opts])
    end
  end

  @spec modules([CodeSearch.fact()]) :: %{optional(String.t()) => [CodeSearch.fact()]}
  defp modules(facts) do
    definitions = definition_facts(facts)

    facts
    |> Enum.map(&fact_value(&1, :module))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Map.new(fn module -> {module, definitions_for_module(definitions, module)} end)
  end

  @spec definition_facts([CodeSearch.fact()]) :: [CodeSearch.fact()]
  defp definition_facts(facts) do
    facts
    |> Enum.filter(&definition?/1)
    |> Enum.sort_by(&definition_sort_key/1)
  end

  @spec definitions_for_module([CodeSearch.fact()], String.t()) :: [CodeSearch.fact()]
  defp definitions_for_module(definitions, module) do
    Enum.filter(definitions, &(fact_value(&1, :module) == module))
  end

  @spec definition?(CodeSearch.fact()) :: boolean()
  defp definition?(fact) do
    fact_value(fact, :kind) in [:def, :defp, "def", "defp"] and not blank?(fact_value(fact, :name))
  end

  @spec definition_sort_key(CodeSearch.fact()) :: {String.t(), integer(), String.t()}
  defp definition_sort_key(fact) do
    {
      to_string(fact_value(fact, :module)),
      fact_value(fact, :line) || 0,
      to_string(fact_value(fact, :name))
    }
  end

  @spec selected_project?(Project.t() | nil, Project.t()) :: boolean()
  defp selected_project?(%Project{name: selected}, %Project{name: name}), do: selected == name
  defp selected_project?(_selected, _project), do: false

  @spec project_name(Project.t() | nil) :: String.t()
  defp project_name(%Project{name: name}), do: name
  defp project_name(nil), do: ""

  @spec symbol(CodeSearch.fact()) :: String.t()
  defp symbol(fact) do
    module = fact_value(fact, :module)
    name = fact_value(fact, :name)
    arity = fact_value(fact, :arity)

    [module, name]
    |> Enum.reject(&blank?/1)
    |> Enum.join(".")
    |> then(&"#{&1}/#{arity}")
  end

  @spec definition_label(CodeSearch.fact()) :: String.t()
  defp definition_label(fact), do: "#{fact_value(fact, :name)}/#{fact_value(fact, :arity)}"

  @spec kind_label(CodeSearch.fact()) :: String.t()
  defp kind_label(fact), do: fact |> fact_value(:kind) |> to_string()

  @spec edge_symbol(CodeSearch.fact(), :caller | :callee) :: String.t()
  defp edge_symbol(fact, :caller), do: fact_value(fact, :caller) || symbol(fact)
  defp edge_symbol(fact, :callee), do: fact_value(fact, :callee) || symbol(fact)

  @spec edge_pair(CodeSearch.fact()) :: String.t()
  defp edge_pair(fact) do
    caller = fact_value(fact, :caller) || "unknown caller"
    callee = fact_value(fact, :callee) || "unknown callee"

    "#{caller} -> #{callee}"
  end

  @spec location(CodeSearch.fact()) :: String.t()
  defp location(fact) do
    file = fact_value(fact, :file) || "unknown"
    line = fact_value(fact, :line)

    if is_integer(line), do: "#{file}:#{line}", else: file
  end

  @spec empty_title(empty_state()) :: String.t()
  defp empty_title(:no_projects), do: "No projects registered"
  defp empty_title(:unknown_project), do: "Project not registered"
  defp empty_title(:unsupported_language), do: "Elixir projects only"
  defp empty_title(:code_search_unavailable), do: "Code search unavailable"

  @spec empty_message(empty_state(), Project.t() | nil, term()) :: String.t()
  defp empty_message(:no_projects, _project, _reason), do: "Register a project before exploring its structure."
  defp empty_message(:unknown_project, _project, {:unknown_project, name}), do: "#{name} is not registered."

  defp empty_message(:unsupported_language, %Project{language: language}, _reason) do
    "Harness.CodeSearch is Elixir-only; this project is #{language}."
  end

  defp empty_message(:code_search_unavailable, _project, :exograph_unavailable) do
    "The exograph dependency is not available, so structural facts cannot be loaded."
  end

  defp empty_message(:code_search_unavailable, _project, reason) do
    "Structural facts could not be loaded: #{inspect(reason)}"
  end

  @spec fact_value(map(), atom()) :: term()
  defp fact_value(fact, key), do: Map.get(fact, key) || Map.get(fact, Atom.to_string(key))

  @spec blank?(term()) :: boolean()
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
