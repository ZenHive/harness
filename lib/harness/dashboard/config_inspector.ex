defmodule Harness.Dashboard.ConfigInspector do
  @moduledoc """
  Read-only resolver for the harness node's *effective* configuration (Task 127),
  rendered from the `Harness.Config` schema (Task 167).

  Surfaces the value actually in application env — after `config/config.exs`
  defaults, `config/runtime.exs` env-var overrides, and persisted UI overrides —
  grouped by concern, so an operator can see how the node is configured (what
  reboots vs. what an env var changes) without shell access to the config files.
  The simple keyed config comes from `Harness.Config.schema/0` (defaults live
  there, in one place); the two trailing *derived* sections (result store,
  settings store backend) are `*.configured/0` computations, not schema keys, so
  they stay inspector-local. Mutation of the `ui_editable?` keys lives on the same
  `SettingsLive` page; this module only reads.

  ## Provenance is a heuristic, not a recording

  At runtime a compile-time default and a `config.exs` override are
  indistinguishable — both are already folded into app env. So provenance is
  *reconstructed*, not recorded: if an env var that overrides the key is set the
  row is `:env`; else if the resolved value differs from the schema's baked-in
  default it is `:config`; else `:default`. The `:config`-vs-`:default` split is
  therefore a best-effort inference from value-difference, not ground truth.

  ## Secrets never render

  `secret?: true` schema entries render `"[redacted]"` regardless of value, and
  the database section surfaces only `database` / `username` / `hostname` — never
  the password or a connection URL.
  """

  alias Harness.Config
  alias Harness.Config.Entry
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.SettingsStore

  @type provenance :: :default | :config | :env

  @type row :: %{
          label: String.t(),
          value: String.t(),
          provenance: provenance(),
          env_var: String.t() | nil
        }

  @type section :: %{title: String.t(), rows: [row()]}

  @redacted "[redacted]"

  @doc """
  Resolves the full effective config as an ordered list of titled sections.

  The leading sections are the `Harness.Config` schema grouped by concern, then
  the derived store sections, then the projects registered with
  `Harness.ProjectRegistry`.
  """
  @spec resolve() :: [section()]
  def resolve do
    schema_sections() ++ Enum.map(derived_sections(), &build_section/1) ++ [projects_section()]
  end

  # ── Schema-driven sections ──────────────────────────────────────────────────

  # Groups the ordered schema by `section` (entries are declared section-by-section,
  # so consecutive chunking preserves declaration order within each concern).
  @spec schema_sections() :: [section()]
  defp schema_sections do
    Config.schema()
    |> Enum.chunk_by(& &1.section)
    |> Enum.map(fn entries -> %{title: hd(entries).section, rows: Enum.map(entries, &schema_row/1)} end)
  end

  @spec schema_row(Entry.t()) :: row()
  defp schema_row(%Entry{} = entry) do
    resolved = Config.get(entry.key)

    inspector_row(
      entry.label,
      schema_value(entry, resolved),
      provenance(entry.env_var, resolved, entry.default),
      entry.env_var
    )
  end

  # Secret entries never render their value; everything else is formatted by type.
  @spec schema_value(Entry.t(), term()) :: String.t()
  defp schema_value(%Entry{secret?: true}, _resolved), do: @redacted
  defp schema_value(%Entry{type: :duration_ms}, resolved), do: ms(resolved)
  defp schema_value(%Entry{type: :atom_list}, resolved), do: sinks_label(resolved)
  defp schema_value(%Entry{}, resolved), do: format_value(resolved)

  # ── Derived sections (computed, not schema keys) ────────────────────────────

  @spec derived_sections() :: [{String.t(), [map()]}]
  defp derived_sections do
    [
      {"Result store",
       [
         field("backend", fn -> store_part(:backend) end, result_store_default(:backend), format: &inspect/1),
         field("root", fn -> store_part(:root) end, result_store_default(:root))
       ]},
      {"Settings store",
       [
         field("backend", fn -> settings_store_part(:backend) end, settings_store_default(:backend), format: &inspect/1),
         field("root", fn -> settings_store_part(:root) end, settings_store_default(:root))
       ]}
    ]
  end

  @spec build_section({String.t(), [map()]}) :: section()
  defp build_section({title, fields}) do
    %{title: title, rows: Enum.map(fields, &build_row/1)}
  end

  @spec build_row(map()) :: row()
  defp build_row(field) do
    resolved = field.read.()

    inspector_row(field.label, row_value(field, resolved), provenance(nil, resolved, field.default))
  end

  @spec row_value(map(), term()) :: String.t()
  defp row_value(%{format: format}, resolved) when is_function(format, 1), do: format.(resolved)
  defp row_value(_field, resolved), do: format_value(resolved)

  @spec field(String.t(), (-> term()), term(), keyword()) :: map()
  defp field(label, read, default, opts \\ []) do
    %{label: label, read: read, default: default, format: Keyword.get(opts, :format)}
  end

  # ── Shared formatting / provenance ──────────────────────────────────────────

  @spec provenance(String.t() | nil, term(), term()) :: provenance()
  defp provenance(env_var, resolved, default) do
    cond do
      is_binary(env_var) and System.get_env(env_var) != nil -> :env
      resolved != default -> :config
      true -> :default
    end
  end

  @spec format_value(term()) :: String.t()
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(nil), do: "—"
  defp format_value(value), do: inspect(value)

  # Humanizes a millisecond duration as "<human> (<n> ms)" — keeps the raw ms
  # for precision since this is an inspector. Sub-second / non-round values fall
  # back to bare ms; a nil (unset) timeout renders as "—".
  @spec ms(term()) :: String.t()
  defp ms(value) when is_integer(value) do
    case human_duration(value) do
      nil -> "#{value} ms"
      human -> "#{human} (#{value} ms)"
    end
  end

  defp ms(value), do: format_value(value)

  @spec human_duration(integer()) :: String.t() | nil
  defp human_duration(n) when n >= 60_000 and rem(n, 60_000) == 0, do: "#{div(n, 60_000)} min"
  defp human_duration(n) when n >= 1_000 and rem(n, 1_000) == 0, do: "#{div(n, 1_000)} s"
  defp human_duration(_n), do: nil

  @spec sinks_label([module()]) :: String.t()
  defp sinks_label([]), do: "none (silent)"
  defp sinks_label(sinks), do: Enum.map_join(sinks, ", ", &inspect/1)

  # ── Derived-store readers ───────────────────────────────────────────────────

  # `ResultStore.configured/0` is `{module, opts}`, or `false`/`nil` when off.
  @spec store_part(:backend | :root) :: term()
  defp store_part(:backend) do
    case ResultStore.configured() do
      {module, _opts} -> module
      _disabled -> "disabled"
    end
  end

  defp store_part(:root) do
    case ResultStore.configured() do
      {ResultStore.Postgres, _opts} -> "database:run_records"
      {ResultStore.Memory, _opts} -> "memory:ephemeral"
      {_module, opts} -> Keyword.get(opts, :root)
      _disabled -> "disabled"
    end
  end

  @spec result_store_default(:backend | :root) :: term()
  defp result_store_default(:backend) do
    if Application.get_env(:harness, :repo_enabled, true), do: ResultStore.Postgres, else: ResultStore.Memory
  end

  defp result_store_default(:root) do
    if Application.get_env(:harness, :repo_enabled, true), do: "database:run_records", else: "memory:ephemeral"
  end

  # `SettingsStore.configured/0` is `{module, opts}` (Postgres when repo_enabled)
  # or `false` (the ephemeral no-op store). Postgres has no path; it lives in the
  # harness_settings table.
  @spec settings_store_part(:backend | :root) :: term()
  defp settings_store_part(:backend) do
    case SettingsStore.configured() do
      {module, _opts} -> module
      _ephemeral -> "ephemeral"
    end
  end

  defp settings_store_part(:root) do
    case SettingsStore.configured() do
      {SettingsStore.Postgres, _opts} -> "database:harness_settings"
      {_module, opts} -> Keyword.get(opts, :root)
      _ephemeral -> "memory:ephemeral"
    end
  end

  @spec settings_store_default(:backend | :root) :: term()
  defp settings_store_default(:backend) do
    if Application.get_env(:harness, :repo_enabled, true), do: SettingsStore.Postgres, else: "ephemeral"
  end

  defp settings_store_default(:root) do
    if Application.get_env(:harness, :repo_enabled, true), do: "database:harness_settings", else: "memory:ephemeral"
  end

  # ── Projects ────────────────────────────────────────────────────────────────

  @spec projects_section() :: section()
  defp projects_section do
    rows =
      case ProjectRegistry.list() do
        [] -> [empty_row("No projects registered.")]
        projects -> Enum.map(projects, &project_row/1)
      end

    %{title: "Registered projects", rows: rows}
  end

  @spec project_row(Project.t()) :: row()
  defp project_row(%Project{} = project) do
    summary =
      Enum.join(
        [
          source_label(project.source),
          "languages=#{language_list(project.languages)}",
          "roadmap=#{project.roadmap_path}",
          "cap=#{project.concurrency_cap || "∞"}",
          check_command_label(project.check_command)
        ],
        " · "
      )

    inspector_row(project.name, summary, :config)
  end

  @spec language_list([atom()]) :: String.t()
  defp language_list(languages), do: Enum.map_join(languages, ",", &Atom.to_string/1)

  @spec source_label(Project.Source.Local.t() | Project.Source.Github.t()) :: String.t()
  defp source_label({:local, dir}), do: "local:#{dir}"
  defp source_label({:github, url}), do: "github:#{url}"

  # The check_command is a hint handed to the reviewer AI (the gate runs the
  # checks itself); "none" means the reviewer decides what to run unaided.
  @spec check_command_label(String.t() | nil) :: String.t()
  defp check_command_label(nil), do: "check=none"
  defp check_command_label(command), do: "check=#{command}"

  @spec empty_row(String.t()) :: row()
  defp empty_row(text), do: inspector_row(text, "", :default)

  @spec inspector_row(String.t(), String.t(), provenance(), String.t() | nil) :: row()
  defp inspector_row(label, value, provenance, env_var \\ nil) do
    %{label: label, value: value, provenance: provenance, env_var: env_var}
  end
end
