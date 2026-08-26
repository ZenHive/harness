defmodule Harness.SettingsStore.PostgresCodecTest do
  use ExUnit.Case, async: false

  alias Harness.SettingsStore.Postgres
  alias Harness.SettingsStore.Schema.Setting

  defmodule FakeRepo do
    @moduledoc false

    @spec get(module(), String.t()) :: Setting.t()
    def get(Setting, key), do: %Setting{key: key, payload: Process.get({__MODULE__, :payload})}
  end

  test "fetch restores a persisted setting containing an atom absent from the reading node" do
    name = "settings_cold_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

    payload = <<131, 100, byte_size(name)::16, name::binary>>
    Process.put({FakeRepo, :payload}, payload)

    assert_raise ArgumentError, fn -> :erlang.binary_to_term(payload, [:safe]) end
    assert {:ok, atom} = Postgres.fetch("cold-setting", repo: FakeRepo)
    assert Atom.to_string(atom) == name
  end
end
