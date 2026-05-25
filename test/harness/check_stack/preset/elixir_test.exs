defmodule Harness.CheckStack.Preset.ElixirTest do
  use ExUnit.Case, async: true

  alias Harness.CheckStack
  alias Harness.CheckStack.Preset
  alias Harness.Verification.Check

  describe "preset/0" do
    test "returns a %CheckStack{} named :elixir" do
      assert %CheckStack{name: :elixir} = Preset.Elixir.preset()
    end

    test "carries the five-tool mix quality stack in the expected order" do
      %CheckStack{checks: checks} = Preset.Elixir.preset()

      assert length(checks) == 5
      assert Enum.all?(checks, &match?(%Check{command: "mix"}, &1))
      assert Enum.map(checks, & &1.name) == ~w(test dialyzer credo doctor sobelow)
    end

    test "the sobelow check still carries --exit and --skip" do
      # `--exit` makes sobelow's exit status the pass/fail signal; `--skip`
      # honors the repo's inline `# sobelow_skip` annotations.
      sobelow = Enum.find(Preset.Elixir.preset().checks, &(&1.name == "sobelow"))
      assert "--exit" in sobelow.args
      assert "--skip" in sobelow.args
    end

    test "the credo check still declares the TagTODO baseline filter" do
      credo = Enum.find(Preset.Elixir.preset().checks, &(&1.name == "credo"))
      assert credo.post_process == {Harness.Verification.BaselineFilter.Credo, :apply}
    end

    test "leaves parser and timeout_per_check nil (verification default wins)" do
      stack = Preset.Elixir.preset()
      assert stack.parser == nil
      assert stack.timeout_per_check == nil
    end
  end
end
