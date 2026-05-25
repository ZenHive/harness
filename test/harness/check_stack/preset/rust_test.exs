defmodule Harness.CheckStack.Preset.RustTest do
  use ExUnit.Case, async: true

  alias Harness.CheckStack
  alias Harness.CheckStack.Preset
  alias Harness.Verification
  alias Harness.Verification.Check
  alias Harness.Verification.Verdict

  @fixture_root Path.expand("../../../support/fixtures", __DIR__)

  describe "preset/0" do
    test "returns a %CheckStack{} named :rust" do
      assert %CheckStack{name: :rust} = Preset.Rust.preset()
    end

    test "carries the canonical cargo quality stack in the expected order" do
      %CheckStack{checks: checks} = Preset.Rust.preset()

      assert [
               %Check{name: "fmt", command: "cargo", args: ["fmt", "--check"], role: :format},
               %Check{name: "clippy", command: "cargo", args: ["clippy", "--", "-D", "warnings"], role: :lint},
               %Check{name: "test", command: "cargo", args: ["test", "--message-format=json"], role: :test},
               %Check{name: "build", command: "cargo", args: ["build", "--release"], role: :build}
             ] = checks
    end

    test "leaves parser and timeout_per_check nil" do
      stack = Preset.Rust.preset()
      assert stack.parser == nil
      assert stack.timeout_per_check == nil
    end
  end

  describe "verification with the Rust preset" do
    test "passes a green Rust fixture and captures cargo JSON output" do
      project = copy_fixture!("rust_project")

      assert {:ok, %Verdict{status: :pass, results: results}} =
               Verification.run(project, check_stack: Preset.Rust.preset())

      assert Enum.map(results, & &1.status) == [:pass, :pass, :pass, :pass]

      test_result = Enum.find(results, &(&1.name == "test"))
      assert test_result.output =~ ~s("reason":"compiler-artifact")
    end

    test "fails a Rust fixture with a failing cargo test" do
      project = copy_fixture!("rust_project_failing_test")

      assert {:ok, %Verdict{status: :fail, results: results}} =
               Verification.run(project, check_stack: Preset.Rust.preset())

      assert [
               %_{name: "fmt", status: :pass},
               %_{name: "clippy", status: :pass},
               %_{name: "test", status: :fail},
               %_{name: "build", status: :pass}
             ] = results
    end
  end

  defp copy_fixture!(name) do
    source = Path.join(@fixture_root, name)
    dest = Path.join(System.tmp_dir!(), "harness_#{name}_#{System.unique_integer([:positive])}")
    File.cp_r!(source, dest)
    on_exit(fn -> File.rm_rf!(dest) end)
    dest
  end
end
