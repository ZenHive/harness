defmodule Harness.CheckStack.PresetTest do
  use ExUnit.Case, async: true

  alias Harness.CheckStack
  alias Harness.CheckStack.Preset
  alias Harness.CheckStack.Preset.Elixir, as: ElixirPreset
  alias Harness.CheckStack.Preset.Rust, as: RustPreset

  describe "fetch/1" do
    test "fetch(:elixir) returns the Elixir preset wired through Preset.Elixir" do
      assert {:ok, %CheckStack{name: :elixir} = stack} = Preset.fetch(:elixir)
      # The registry must return the same value the per-language submodule
      # exposes — i.e. they must be wired, not two parallel definitions.
      assert stack == ElixirPreset.preset()
    end

    test "fetch(:rust) returns the Rust preset wired through Preset.Rust" do
      assert {:ok, %CheckStack{name: :rust} = stack} = Preset.fetch(:rust)
      assert stack == RustPreset.preset()
    end

    test "fetch(:elixir_precommit) returns the mergeable-bar stack" do
      assert {:ok, %CheckStack{name: :elixir_precommit} = stack} = Preset.fetch(:elixir_precommit)
      assert stack == ElixirPreset.precommit()
    end

    test "unknown presets return {:error, {:unknown_preset, name}}" do
      assert Preset.fetch(:cobol) == {:error, {:unknown_preset, :cobol}}
      assert Preset.fetch(:python) == {:error, {:unknown_preset, :python}}
    end
  end

  describe "fetch/2 — parameterized presets" do
    test "fetch(:elixir_precommit, opts) threads cover_threshold and exclude through" do
      assert {:ok, stack} = Preset.fetch(:elixir_precommit, cover_threshold: 90, exclude: [:integration])
      assert stack == ElixirPreset.precommit(cover_threshold: 90, exclude: [:integration])

      test_check = Enum.find(stack.checks, &(&1.name == "test"))
      assert "90" in test_check.args
      assert "integration" in test_check.args
    end

    test "fetch(:elixir_precommit, opts) threads include tags and database provisioning through" do
      assert {:ok, stack} = Preset.fetch(:elixir_precommit, include: [:integration], database: :postgres)

      test_check = Enum.find(stack.checks, &(&1.name == "test"))
      assert "--include" in test_check.args
      assert "integration" in test_check.args
      assert test_check.env == %{"MIX_ENV" => "test", "HARNESS_DB_NAME" => {:harness, :test_database}}
      assert Enum.map(stack.setup, & &1.name) == ["deps", "deps.compile", "test-db-create", "test-db-migrate"]
    end

    test "non-precommit presets ignore opts and resolve like fetch/1" do
      assert Preset.fetch(:elixir, cover_threshold: 90) == Preset.fetch(:elixir)
      assert Preset.fetch(:cobol, []) == {:error, {:unknown_preset, :cobol}}
    end

    test "fetch(:rust, opts) threads target_dir/release/timeout/env through Preset.Rust" do
      assert {:ok, stack} = Preset.fetch(:rust, release: false, target_dir: "/c", env: %{"D" => "u"})
      assert stack == RustPreset.preset(release: false, target_dir: "/c", env: %{"D" => "u"})

      testc = Enum.find(stack.checks, &(&1.name == "test"))
      assert "--target-dir" in testc.args
      assert "/c" in testc.args
      refute "--release" in Enum.find(stack.checks, &(&1.name == "build")).args
      assert testc.env == %{"D" => "u"}
      assert stack.timeout_per_check == nil
    end

    test "fetch(:rust, opts) with timeout_per_check and bare :rust back-compat" do
      assert {:ok, s1} = Preset.fetch(:rust, timeout_per_check: 123_000)
      assert s1.timeout_per_check == 123_000

      assert Preset.fetch(:rust, []) == Preset.fetch(:rust)
      assert Preset.fetch(:rust) == {:ok, RustPreset.preset()}
    end
  end
end
