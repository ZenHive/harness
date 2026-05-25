defmodule Harness.CheckStack.PresetTest do
  use ExUnit.Case, async: true

  alias Harness.CheckStack
  alias Harness.CheckStack.Preset
  alias Harness.CheckStack.Preset.Elixir, as: ElixirPreset

  describe "fetch/1" do
    test "fetch(:elixir) returns the Elixir preset wired through Preset.Elixir" do
      assert {:ok, %CheckStack{name: :elixir} = stack} = Preset.fetch(:elixir)
      # The registry must return the same value the per-language submodule
      # exposes — i.e. they must be wired, not two parallel definitions.
      assert stack == ElixirPreset.preset()
    end

    test "unknown presets return {:error, {:unknown_preset, name}}" do
      assert Preset.fetch(:cobol) == {:error, {:unknown_preset, :cobol}}
      assert Preset.fetch(:python) == {:error, {:unknown_preset, :python}}
    end
  end
end
