defmodule Harness.DepFreshness.Provider.JavaScriptTest do
  use ExUnit.Case, async: true

  alias Harness.DepFreshness.Provider.JavaScript, as: Provider
  alias Harness.DepFreshness.Row
  alias Harness.ProjectFixture

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "harness-js-freshness-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "detect_package_manager/2 reads explicit packageManager metadata", %{tmp_dir: tmp_dir} do
    assert {:ok, :pnpm} = Provider.detect_package_manager(tmp_dir, %{"packageManager" => "pnpm@9.0.0"})
    assert {:ok, :yarn} = Provider.detect_package_manager(tmp_dir, %{"packageManager" => "yarn@4.1.0"})

    assert {:skipped, {:unsupported_package_manager, "bun"}} =
             Provider.detect_package_manager(tmp_dir, %{"packageManager" => "bun@1.0.0"})

    assert {:skipped, {:invalid_package_manager, "pnpm"}} =
             Provider.detect_package_manager(tmp_dir, %{"packageManager" => "pnpm"})
  end

  test "detect_package_manager/2 reads supported lockfiles and skips ambiguous metadata", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "package-lock.json"), "{}")
    assert {:ok, :npm} = Provider.detect_package_manager(tmp_dir, %{})

    File.write!(Path.join(tmp_dir, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n")

    assert {:skipped, {:ambiguous_package_manager, [:npm, :pnpm]}} =
             Provider.detect_package_manager(tmp_dir, %{})
  end

  test "parse_output/3 maps npm and pnpm JSON rows mechanically" do
    output =
      Jason.encode!(%{
        "phoenix" => %{"current" => "1.0.0", "wanted" => "1.1.0", "latest" => "1.1.0"},
        "vite" => %{"current" => "5.0.0", "wanted" => "5.2.0", "latest" => "6.0.0"}
      })

    assert {:ok, rows} = Provider.parse_output(:npm, output, %{"phoenix" => "^1.0.0", "vite" => "^5.0.0"})

    assert %Row{
             name: "phoenix",
             current_version: "1.0.0",
             latest_version: "1.1.0",
             constraint_allowed: true
           } = Enum.find(rows, &(&1.name == "phoenix"))

    assert %Row{
             name: "vite",
             current_version: "5.0.0",
             latest_version: "6.0.0",
             constraint_allowed: false
           } = Enum.find(rows, &(&1.name == "vite"))
  end

  test "parse_output/3 maps yarn classic table JSON rows" do
    output =
      Jason.encode!(%{
        "type" => "table",
        "data" => %{
          "head" => ["Package", "Current", "Wanted", "Latest", "Package Type"],
          "body" => [["typescript", "5.4.0", "5.5.4", "5.5.4", "devDependencies"]]
        }
      })

    assert {:ok, [%Row{name: "typescript", current_version: "5.4.0", latest_version: "5.5.4", constraint_allowed: true}]} =
             Provider.parse_output(:yarn, output, %{"typescript" => "^5.4.0"})
  end

  test "parse_output/3 accepts empty outputs and generic yarn JSON" do
    assert {:ok, []} = Provider.parse_output(:npm, " \n", %{})
    assert {:ok, []} = Provider.parse_output(:pnpm, "{}", %{})

    output = Jason.encode!(%{"react" => %{"current" => "18.2.0", "wanted" => "18.3.1", "latest" => "18.3.1"}})

    assert {:ok, [%Row{name: "react", constraint_allowed: true}]} =
             Provider.parse_output(:yarn, output, %{"react" => "^18.2.0"})
  end

  test "parse_output/3 handles array rows, exact constraints, and malformed payloads" do
    array_output =
      Jason.encode!([
        %{"name" => "exact", "current" => 1, "latest" => "1.2.3"},
        %{"name" => "unknown", "current" => 1.0, "latest" => "2.0.0"},
        "ignored"
      ])

    assert {:ok, rows} = Provider.parse_output(:pnpm, array_output, %{"exact" => "1.2.3", "unknown" => "^1.0.0"})

    assert %Row{name: "exact", current_version: "1", constraint_allowed: true} =
             Enum.find(rows, &(&1.name == "exact"))

    assert %Row{name: "unknown", current_version: "1.0", constraint_allowed: false} =
             Enum.find(rows, &(&1.name == "unknown"))

    ignored_output = Jason.encode!(["ignored"])

    assert {:error, {:parse_failed, "not json"}} = Provider.parse_output(:npm, "not json", %{})
    assert {:error, {:parse_failed, ^ignored_output}} = Provider.parse_output(:npm, ignored_output, %{})
    assert {:error, {:parse_failed, ~s({"error":"boom"})}} = Provider.parse_output(:npm, ~s({"error":"boom"}), %{})
  end

  test "scan/3 uses detected npm command without installing packages", %{tmp_dir: tmp_dir} do
    write_package_json!(tmp_dir, %{"react" => "^18.2.0"})
    File.write!(Path.join(tmp_dir, "package-lock.json"), "{}")

    runner = fn "npm", ["outdated", "--json"], ^tmp_dir ->
      {:ok, Jason.encode!(%{"react" => %{"current" => "18.2.0", "wanted" => "18.3.1", "latest" => "19.0.0"}})}
    end

    project = ProjectFixture.from_repo(tmp_dir, name: "npm-app", language: :javascript)

    assert {:ok, [%Row{name: "react", constraint_allowed: false}]} = Provider.scan(project, tmp_dir, runner: runner)
  end

  test "scan/3 skips visibly when package manager metadata is missing", %{tmp_dir: tmp_dir} do
    write_package_json!(tmp_dir, %{"react" => "^18.2.0"})
    project = ProjectFixture.from_repo(tmp_dir, name: "missing-manager", language: :typescript)

    assert {:skipped, :missing_package_manager_metadata} =
             Provider.scan(project, tmp_dir, runner: fn _, _, _ -> flunk("runner should not run") end)
  end

  test "scan/3 skips visibly when package.json is missing or invalid", %{tmp_dir: tmp_dir} do
    project = ProjectFixture.from_repo(tmp_dir, name: "missing-package-json", language: :javascript)

    assert {:skipped, :missing_package_json} =
             Provider.scan(project, tmp_dir, runner: fn _, _, _ -> flunk("runner should not run") end)

    File.write!(Path.join(tmp_dir, "package.json"), "[")

    assert {:skipped, {:invalid_package_json, _message}} =
             Provider.scan(project, tmp_dir, runner: fn _, _, _ -> flunk("runner should not run") end)

    File.write!(Path.join(tmp_dir, "package.json"), "[]")

    assert {:skipped, :invalid_package_json} =
             Provider.scan(project, tmp_dir, runner: fn _, _, _ -> flunk("runner should not run") end)
  end

  @spec write_package_json!(String.t(), %{String.t() => String.t()}) :: :ok
  defp write_package_json!(dir, deps) do
    File.write!(Path.join(dir, "package.json"), Jason.encode!(%{"dependencies" => deps}))
  end
end
