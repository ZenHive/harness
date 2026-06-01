defmodule Harness.CheckStack.Preset do
  @moduledoc """
  Registry that fetches a built-in `Harness.CheckStack` by language key.

  Built-in per-language presets add a clause here that returns the preset
  module's `preset/0` call, so callers never reach across to a specific
  submodule.

      iex> {:ok, stack} = Harness.CheckStack.Preset.fetch(:elixir)
      iex> stack.name
      :elixir

      iex> Harness.CheckStack.Preset.fetch(:cobol)
      {:error, {:unknown_preset, :cobol}}
  """

  alias Harness.CheckStack
  alias Harness.CheckStack.Preset.Elixir, as: ElixirPreset
  alias Harness.CheckStack.Preset.Rust, as: RustPreset

  @typedoc "Reason fetching a preset failed."
  @type error :: {:unknown_preset, atom()}

  @doc """
  Returns the named built-in `Harness.CheckStack`, or `{:error, {:unknown_preset, name}}`.

  The returned stack carries every check the registered preset declares; pass
  it straight to `Harness.Verification.run/2` via the `:check_stack` option.

  `:elixir` is the lighter day-to-day stack; `:elixir_precommit` is the
  mergeable-bar stack mirroring `mix precommit` (Task 97). For a parameterized
  `:elixir_precommit` (custom `cover_threshold`, ExUnit tag filters, or
  Postgres test DB provisioning), use `fetch/2`.
  """
  @spec fetch(atom()) :: {:ok, CheckStack.t()} | {:error, error()}
  def fetch(:elixir), do: {:ok, ElixirPreset.preset()}
  def fetch(:elixir_precommit), do: {:ok, ElixirPreset.precommit()}
  def fetch(:rust), do: {:ok, RustPreset.preset()}
  def fetch(name) when is_atom(name), do: {:error, {:unknown_preset, name}}

  @doc """
  Returns a parameterized built-in `Harness.CheckStack`.

  Only `:elixir_precommit` reads `opts` (`:cover_threshold`, `:exclude`,
  `:include`, `:database` — see `Harness.CheckStack.Preset.Elixir.precommit/1`);
  every other preset ignores them and resolves identically to `fetch/1`. This is
  the form a project's registration config uses to declare its own merge gate,
  e.g. `preset: {:elixir_precommit, cover_threshold: 85, exclude: [:integration]}`.
  """
  @spec fetch(atom(), keyword()) :: {:ok, CheckStack.t()} | {:error, error()}
  def fetch(:elixir_precommit, opts) when is_list(opts), do: {:ok, ElixirPreset.precommit(opts)}
  def fetch(name, opts) when is_atom(name) and is_list(opts), do: fetch(name)
end
