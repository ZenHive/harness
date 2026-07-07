defmodule Harness.DepFreshness.Provider.RustTest do
  use ExUnit.Case, async: true

  alias Harness.DepFreshness.Provider.Rust, as: Provider
  alias Harness.DepFreshness.Row
  alias Harness.ProjectFixture

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "harness-rust-freshness-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  @sample_output Jason.encode!(%{
                   "crate_name" => "app",
                   "dependencies" => [
                     %{
                       "name" => "serde",
                       "project" => "1.0.0",
                       "compat" => "1.0.228",
                       "latest" => "1.0.228",
                       "kind" => "Normal",
                       "platform" => nil
                     },
                     %{
                       "name" => "pin-project",
                       "project" => "1.0.0",
                       "compat" => "---",
                       "latest" => "1.1.0",
                       "kind" => "Development",
                       "platform" => nil
                     }
                   ]
                 })

  test "parse_output/1 maps cargo outdated JSON rows mechanically" do
    assert {:ok, rows} = Provider.parse_output(@sample_output)

    assert %Row{
             name: "serde",
             current_version: "1.0.0",
             latest_version: "1.0.228",
             constraint_allowed: true
           } = Enum.find(rows, &(&1.name == "serde"))

    assert %Row{
             name: "pin-project",
             current_version: "1.0.0",
             latest_version: "1.1.0",
             constraint_allowed: false
           } = Enum.find(rows, &(&1.name == "pin-project"))
  end

  test "parse_output/1 accepts empty dependency lists and rejects malformed payloads" do
    assert {:ok, []} = Provider.parse_output(~s({"crate_name":"app","dependencies":[]}))
    assert {:error, {:parse_failed, "not json"}} = Provider.parse_output("not json")
    assert {:error, {:parse_failed, ~s({"dependencies":"nope"})}} = Provider.parse_output(~s({"dependencies":"nope"}))
  end

  test "scan/3 uses cargo outdated JSON when the subcommand exists", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "Cargo.toml"), cargo_toml())

    runner = fn
      "cargo", ["outdated", "--version"], ^tmp_dir ->
        {:ok, "cargo-outdated-outdated 0.19.0"}

      "cargo", ["outdated", "--format", "json", "-R"], ^tmp_dir ->
        {:ok, @sample_output}
    end

    project = ProjectFixture.from_repo(tmp_dir, name: "rust-app", language: :rust)

    assert {:ok, rows} = Provider.scan(project, tmp_dir, runner: runner)
    assert Enum.any?(rows, &(&1.name == "serde"))
  end

  test "scan/3 installs and uses local cargo-outdated when the cargo subcommand is missing", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "Cargo.toml"), cargo_toml())

    runner = fn
      "cargo", ["outdated", "--version"], ^tmp_dir ->
        {:error, :missing_subcommand}

      cmd, ["outdated", "--version"], ^tmp_dir when is_binary(cmd) ->
        assert String.ends_with?(cmd, "cargo-outdated")
        {:error, :missing_local_binary}

      "cargo", ["install", "cargo-outdated", "--locked", "--root", root], ^tmp_dir ->
        assert String.ends_with?(root, "harness-cargo-outdated")
        {:ok, "installed"}

      cmd, ["outdated", "--format", "json", "-R"], ^tmp_dir when is_binary(cmd) ->
        assert String.ends_with?(cmd, "cargo-outdated")
        {:ok, @sample_output}
    end

    project = ProjectFixture.from_repo(tmp_dir, name: "rust-app", language: :rust)

    assert {:ok, [%Row{name: "serde"} | _rows]} = Provider.scan(project, tmp_dir, runner: runner)
  end

  test "scan/3 skips visibly when Cargo.toml is missing", %{tmp_dir: tmp_dir} do
    project = ProjectFixture.from_repo(tmp_dir, name: "missing-cargo-toml", language: :rust)

    assert {:skipped, :missing_cargo_toml} =
             Provider.scan(project, tmp_dir, runner: fn _, _, _ -> flunk("runner should not run") end)
  end

  @spec cargo_toml() :: String.t()
  defp cargo_toml do
    """
    [package]
    name = "rust_app"
    version = "0.1.0"
    edition = "2021"

    [dependencies]
    serde = "=1.0.0"
    """
  end
end
