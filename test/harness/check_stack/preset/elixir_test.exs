defmodule Harness.CheckStack.Preset.ElixirTest do
  use ExUnit.Case, async: true

  alias Harness.CheckStack
  alias Harness.CheckStack.Preset
  alias Harness.Verification.BaselineFilter.Credo
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
      assert credo.post_process == {Credo, :apply}
    end

    test "declares mix deps.get + deps.compile as setup bootstrap steps" do
      %CheckStack{setup: setup} = Preset.Elixir.preset()

      assert [
               %Check{name: "deps", command: "mix", args: ["deps.get"]},
               %Check{name: "deps.compile", command: "mix", args: ["deps.compile"]}
             ] = setup
    end

    test "leaves parser and timeout_per_check nil (verification default wins)" do
      stack = Preset.Elixir.preset()
      assert stack.parser == nil
      assert stack.timeout_per_check == nil
    end
  end

  describe "precommit/1" do
    test "returns a %CheckStack{} named :elixir_precommit" do
      assert %CheckStack{name: :elixir_precommit} = Preset.Elixir.precommit()
    end

    test "mirrors the mergeable bar: adds format, compile, and a coverage gate" do
      %CheckStack{checks: checks} = Preset.Elixir.precommit()

      assert Enum.all?(checks, &match?(%Check{command: "mix"}, &1))

      assert Enum.map(checks, & &1.name) ==
               ~w(format compile test dialyzer credo doctor sobelow)
    end

    test "format gate checks formatting; compile gate treats warnings as errors" do
      checks = Preset.Elixir.precommit().checks
      assert Enum.find(checks, &(&1.name == "format")).args == ["format", "--check-formatted"]
      assert Enum.find(checks, &(&1.name == "compile")).args == ["compile", "--warnings-as-errors"]
    end

    test "the coverage threshold defaults to 80" do
      test_check = Enum.find(Preset.Elixir.precommit().checks, &(&1.name == "test"))
      assert test_check.args == ["test.json", "--cover", "--cover-threshold", "80"]
    end

    test ":cover_threshold overrides the gate" do
      test_check = Enum.find(Preset.Elixir.precommit(cover_threshold: 95).checks, &(&1.name == "test"))
      assert test_check.args == ["test.json", "--cover", "--cover-threshold", "95"]
    end

    test ":exclude appends --exclude pairs for tags that can't run in a fresh worktree" do
      test_check =
        Enum.find(Preset.Elixir.precommit(exclude: [:integration, :external]).checks, &(&1.name == "test"))

      assert test_check.args ==
               ["test.json", "--cover", "--cover-threshold", "80", "--exclude", "integration", "--exclude", "external"]
    end

    test "doctor gates with --raise so its exit status is load-bearing" do
      doctor = Enum.find(Preset.Elixir.precommit().checks, &(&1.name == "doctor"))
      assert doctor.args == ["doctor", "--raise"]
    end

    test "the credo check still declares the TagTODO baseline filter" do
      credo = Enum.find(Preset.Elixir.precommit().checks, &(&1.name == "credo"))
      assert credo.post_process == {Credo, :apply}
    end

    test "declares mix deps.get + deps.compile as setup bootstrap steps" do
      %CheckStack{setup: setup} = Preset.Elixir.precommit()

      assert [
               %Check{name: "deps", command: "mix", args: ["deps.get"]},
               %Check{name: "deps.compile", command: "mix", args: ["deps.compile"]}
             ] = setup
    end
  end
end
