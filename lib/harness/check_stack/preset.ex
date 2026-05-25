defmodule Harness.CheckStack.Preset do
  @moduledoc """
  Registry that fetches a built-in `Harness.CheckStack` by language key.

  Today only `:elixir` is registered. New per-language presets — `:rust`
  (Task 45) and beyond — add a clause here that returns the preset module's
  `preset/0` call, so callers never reach across to a specific submodule.

      iex> {:ok, stack} = Harness.CheckStack.Preset.fetch(:elixir)
      iex> stack.name
      :elixir

      iex> Harness.CheckStack.Preset.fetch(:cobol)
      {:error, {:unknown_preset, :cobol}}
  """

  alias Harness.CheckStack
  alias Harness.CheckStack.Preset.Elixir, as: ElixirPreset

  @typedoc "Reason fetching a preset failed."
  @type error :: {:unknown_preset, atom()}

  @doc """
  Returns the named built-in `Harness.CheckStack`, or `{:error, {:unknown_preset, name}}`.

  The returned stack carries every check the registered preset declares; pass
  it straight to `Harness.Verification.run/2` via the `:check_stack` option.
  """
  @spec fetch(atom()) :: {:ok, CheckStack.t()} | {:error, error()}
  def fetch(:elixir), do: {:ok, ElixirPreset.preset()}
  def fetch(name) when is_atom(name), do: {:error, {:unknown_preset, name}}
end
