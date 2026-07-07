defmodule Harness.SuiteHealth.CommandsTest do
  use ExUnit.Case, async: true

  alias Harness.ProjectFixture
  alias Harness.SuiteHealth.Commands
  alias Harness.SuiteHealth.Commands.Elixir, as: ElixirCommands
  alias Harness.SuiteHealth.Commands.Rust

  test "elixir command includes integration tests" do
    tmp = Path.join(System.tmp_dir!(), "suite-health-cmd-#{System.unique_integer()}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "mix.exs"), "Mix.install([])")

    on_exit(fn -> File.rm_rf(tmp) end)

    assert {:ok, {"mix", args}} = ElixirCommands.command(ProjectFixture.from_repo(tmp), tmp)
    assert "test.json" in args
    assert "--include" in args
    assert "integration" in args
  end

  test "rust command is cargo test" do
    tmp = Path.join(System.tmp_dir!(), "suite-health-rust-#{System.unique_integer()}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "Cargo.toml"), ~s([package]\nname = "demo"\nversion = "0.1.0"\nedition = "2021"\n))

    on_exit(fn -> File.rm_rf(tmp) end)

    assert {:ok, {"cargo", ["test"]}} = Rust.command(ProjectFixture.from_repo(tmp, languages: [:rust]), tmp)
  end

  test "resolve returns one entry per supported language" do
    tmp = Path.join(System.tmp_dir!(), "suite-health-resolve-#{System.unique_integer()}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "mix.exs"), "Mix.install([])")

    on_exit(fn -> File.rm_rf(tmp) end)

    project = ProjectFixture.from_repo(tmp, languages: [:elixir, :rust])

    assert [
             {:ok, :elixir, ElixirCommands},
             {:ok, :rust, Rust}
           ] = Commands.resolve(project)
  end
end
