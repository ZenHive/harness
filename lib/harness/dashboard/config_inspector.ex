defmodule Harness.Dashboard.ConfigInspector do
  @moduledoc """
  Read-only resolver for the harness node's *effective* configuration (Task 127).

  Surfaces the value actually in application env — after `config/config.exs`
  defaults and `config/runtime.exs` env-var overrides — grouped by concern, so
  an operator can see how the node is configured (what reboots vs. what an env
  var changes) without shell access to the config files. Mutation lives
  elsewhere (the cron / agent toggles on the same `SettingsLive` page); this
  module only reads. `resolve/0` returns an ordered list of titled sections,
  each a list of rows, rendered by `Harness.Dashboard.Components.config_inspector/1`.

  ## Provenance is a heuristic, not a recording

  At runtime a compile-time default and a `config.exs` override are
  indistinguishable — both are already folded into app env. So provenance is
  *reconstructed*, not recorded: if an env var that overrides the key is set the
  row is `:env`; else if the resolved value differs from the baked-in code
  default it is `:config`; else `:default`. The `:config`-vs-`:default` split is
  therefore a best-effort inference from value-difference, not ground truth.

  ## Secrets never render

  `secret?: true` fields render `"[redacted]"` regardless of value, and the
  database section surfaces only `database` / `username` / `hostname` — never
  the password or a connection URL.
  """

  alias Harness.CheckStack
  alias Harness.CheckStack.Preset.Elixir, as: ElixirPreset
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ResultStore

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

  The leading sections are scalar config concerns; the trailing section lists
  the projects registered with `Harness.ProjectRegistry`.
  """
  @spec resolve() :: [section()]
  def resolve do
    Enum.map(config_sections(), &build_section/1) ++ [projects_section()]
  end

  # The declarative surface: one entry per AC concern, each field a map of
  # `label`, a 0-arity `read`, the overriding `env_var` (or nil), the baked-in
  # code `default` for the provenance diff, and optional `secret?` / `format`.
  @spec config_sections() :: [{String.t(), [map()]}]
  defp config_sections do
    [
      {"Dashboard",
       [
         field("enabled", fn -> kw(:dashboard, :enabled, true) end, nil, true),
         field("port", fn -> kw(:dashboard, :port, 4018) end, "HARNESS_DASHBOARD_PORT", 4018),
         secret("secret_key_base", fn -> endpoint(:secret_key_base) end, "HARNESS_SECRET_KEY_BASE")
       ]},
      {"Run timeouts",
       [
         field("total_timeout", fn -> kw(:run, :total_timeout, 1_800_000) end, nil, 1_800_000, format: &ms/1),
         field("idle_timeout", fn -> kw(:run, :idle_timeout, 300_000) end, nil, 300_000, format: &ms/1),
         field("lifetime_timeout", fn -> kw(:run, :lifetime_timeout, 5_400_000) end, nil, 5_400_000, format: &ms/1),
         field("terminal_linger", fn -> kw(:run, :terminal_linger, 5_000) end, nil, 5_000, format: &ms/1),
         field("max_repair_attempts", fn -> kw(:run, :max_repair_attempts, 2) end, nil, 2)
       ]},
      {"Verification",
       [
         field("checks", &check_count/0, nil, default_check_count()),
         field("timeout", fn -> kw(:verification, :timeout, 600_000) end, nil, 600_000, format: &ms/1)
       ]},
      {"Cron polling",
       [
         field("enabled", fn -> kw(:cron_polling, :enabled, false) end, nil, false),
         field("schedule", fn -> kw(:cron_polling, :schedule, "0 */2 * * *") end, nil, "0 */2 * * *")
       ]},
      {"Repair & gating",
       [
         field("cross_agent_repair", fn -> kw(:cross_agent_repair, :enabled, false) end, nil, false),
         field("semantic_gate", fn -> kw(:semantic_gate, :enabled, :auto) end, nil, :auto)
       ]},
      {"Notifications",
       [
         field("sinks", fn -> Application.get_env(:harness, :notification_sinks, []) end, nil, [], format: &sinks_label/1)
       ]},
      {"Result store",
       [
         field("backend", fn -> store_part(:backend) end, nil, ResultStore.File, format: &inspect/1),
         field("root", fn -> store_part(:root) end, nil, Path.expand("~/.harness/results"))
       ]},
      {"Paths",
       [
         field("chat_store root", fn -> kw(:chat_store, :root, nil) end, nil, Path.expand("~/.harness/chats")),
         field("agent_settings root", fn -> settings_root(:agent_settings) end, nil, Path.expand("~/.harness")),
         field("cron_settings root", fn -> settings_root(:cron_settings) end, nil, Path.expand("~/.harness")),
         field(
           "project cache_root",
           fn -> kw(:project, :cache_root, nil) end,
           nil,
           Path.expand("~/_DATA/harness/projects")
         )
       ]},
      {"Worktree",
       [
         field(
           "base_dir",
           fn -> kw(:worktree, :base_dir, nil) end,
           "HARNESS_WORKTREE_ROOT",
           Path.expand("~/_DATA/worktrees/.harness")
         ),
         field("retain_on_failure", fn -> kw(:worktree, :retain_on_failure, true) end, nil, true),
         field("sweep_on_boot", fn -> kw(:worktree, :sweep_on_boot, true) end, nil, true)
       ]},
      {"Retry policy",
       [
         field("max_retries", fn -> kw(:retry_policy, :max_retries, 3) end, nil, 3),
         field("base_delay_ms", fn -> kw(:retry_policy, :base_delay_ms, 1_000) end, nil, 1_000, format: &ms/1),
         field("max_delay_ms", fn -> kw(:retry_policy, :max_delay_ms, 60_000) end, nil, 60_000, format: &ms/1),
         field("multiplier", fn -> kw(:retry_policy, :multiplier, 2.0) end, nil, 2.0)
       ]},
      {"Database",
       [
         field("database", fn -> repo(:database) end, "HARNESS_DB_NAME", nil),
         field("username", fn -> repo(:username) end, "HARNESS_DB_USER", nil),
         field("hostname", fn -> repo(:hostname) end, "HARNESS_DB_HOST", nil)
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

    %{
      label: field.label,
      value: row_value(field, resolved),
      provenance: provenance(field.env_var, resolved, field.default),
      env_var: field.env_var
    }
  end

  # Secret fields never render their value; everything else runs through the
  # field's `format` (defaulting to `format_value/1`).
  @spec row_value(map(), term()) :: String.t()
  defp row_value(%{secret?: true}, _resolved), do: @redacted
  defp row_value(%{format: format}, resolved) when is_function(format, 1), do: format.(resolved)
  defp row_value(_field, resolved), do: format_value(resolved)

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
  # back to bare ms.
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

  # ── Field constructors ────────────────────────────────────────────────────

  @spec field(String.t(), (-> term()), String.t() | nil, term(), keyword()) :: map()
  defp field(label, read, env_var, default, opts \\ []) do
    %{
      label: label,
      read: read,
      env_var: env_var,
      default: default,
      secret?: false,
      format: Keyword.get(opts, :format)
    }
  end

  @spec secret(String.t(), (-> term()), String.t() | nil) :: map()
  defp secret(label, read, env_var) do
    %{label: label, read: read, env_var: env_var, default: nil, secret?: true, format: nil}
  end

  # ── Concern-specific readers ────────────────────────────────────────────────

  @spec kw(atom(), atom(), term()) :: term()
  defp kw(group, key, default) do
    :harness |> Application.get_env(group, []) |> Keyword.get(key, default)
  end

  @spec endpoint(atom()) :: term()
  defp endpoint(key) do
    :harness |> Application.get_env(Harness.Dashboard.Endpoint, []) |> Keyword.get(key)
  end

  @spec repo(atom()) :: term()
  defp repo(key) do
    :harness |> Application.get_env(Harness.Repo, []) |> Keyword.get(key)
  end

  # A store root configured as `false`/`nil` means persistence is off.
  @spec settings_root(atom()) :: term()
  defp settings_root(group) do
    case Application.get_env(:harness, group, []) do
      list when is_list(list) -> Keyword.get(list, :root)
      _disabled -> "disabled"
    end
  end

  # `ResultStore.configured/0` is `{module, opts}`, or `false`/`nil` when off.
  @spec store_part(:backend | :root) :: term()
  defp store_part(part) do
    case ResultStore.configured() do
      {module, _opts} when part == :backend -> module
      {_module, opts} when part == :root -> Keyword.get(opts, :root)
      _disabled -> "disabled"
    end
  end

  @spec check_count() :: non_neg_integer()
  defp check_count do
    case kw(:verification, :checks, nil) do
      nil -> default_check_count()
      checks -> length(checks)
    end
  end

  @spec default_check_count() :: non_neg_integer()
  defp default_check_count, do: length(ElixirPreset.preset().checks)

  @spec sinks_label([module()]) :: String.t()
  defp sinks_label([]), do: "none (silent)"
  defp sinks_label(sinks), do: Enum.map_join(sinks, ", ", &inspect/1)

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
          "roadmap=#{project.roadmap_path}",
          "cap=#{project.concurrency_cap || "∞"}",
          stacks_label(project.check_stacks)
        ],
        " · "
      )

    %{label: project.name, value: summary, provenance: :config, env_var: nil}
  end

  @spec source_label(Project.Source.Local.t() | Project.Source.Github.t()) :: String.t()
  defp source_label({:local, dir}), do: "local:#{dir}"
  defp source_label({:github, url}), do: "github:#{url}"

  @spec stacks_label([CheckStack.t()]) :: String.t()
  defp stacks_label(stacks) do
    "stacks=" <> Enum.map_join(stacks, ", ", fn stack -> "#{stack.name}@#{workdir_label(stack.workdir)}" end)
  end

  @spec workdir_label(String.t()) :: String.t()
  defp workdir_label(""), do: "root"
  defp workdir_label(workdir), do: workdir

  @spec empty_row(String.t()) :: row()
  defp empty_row(text), do: %{label: text, value: "", provenance: :default, env_var: nil}
end
