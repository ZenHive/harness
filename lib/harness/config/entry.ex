defmodule Harness.Config.Entry do
  @moduledoc false
  # One declarative schema row for `Harness.Config`. `key` is the location in
  # `:harness` app env: a `{namespace, subkey}` pair for a keyword-group config
  # (e.g. `{:run, :lifetime_timeout}`, `{Harness.Repo, :database}`) or a bare
  # atom for a flat key (e.g. `:notification_sinks`). `default` is the single
  # source of the baked-in code default; `type` drives both inspector display and
  # editable-input validation.

  @enforce_keys [:section, :label, :key, :default, :type]
  defstruct [
    :section,
    :label,
    :key,
    :default,
    :type,
    env_var: nil,
    ui_editable?: false,
    restart_required?: false,
    secret?: false
  ]

  @typedoc "The app-env location of a config value: a `{namespace, subkey}` group key or a flat atom."
  @type key :: {atom() | module(), atom()} | atom()

  @typedoc "The value's kind — drives inspector formatting and editable-input parsing/validation."
  @type value_type :: :duration_ms | :integer | :boolean | :string | :path | :float | :atom_list

  @type t :: %__MODULE__{
          section: String.t(),
          label: String.t(),
          key: key(),
          default: term(),
          type: value_type(),
          env_var: String.t() | nil,
          ui_editable?: boolean(),
          restart_required?: boolean(),
          secret?: boolean()
        }
end
