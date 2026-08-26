defmodule Harness.ProjectRegistry.OptionalFieldsTest do
  use ExUnit.Case, async: true

  alias Harness.Project
  alias Harness.ProjectRegistry.OptionalFields

  @valid %{
    concurrency_cap: 4,
    pollution_allowlist: ["scratch.txt"],
    warm_paths: ["priv/foo"],
    landing_policy: :auto,
    target_branch: "main",
    reviewer: :codex,
    test_db_isolation_env: "APP_TEST_PARTITION",
    tooling_baseline_overrides: %{"dep:credo" => "legacy"}
  }

  describe "fetch/1" do
    test "returns typed optional fields and fills struct defaults for omitted keys" do
      assert {:ok, fields} = OptionalFields.fetch(%{})

      assert fields == %{
               concurrency_cap: nil,
               pollution_allowlist: nil,
               warm_paths: [],
               landing_policy: :manual,
               target_branch: nil,
               reviewer: nil,
               test_db_isolation_env: nil,
               tooling_baseline_overrides: %{}
             }
    end

    test "round-trips a fully populated valid map" do
      assert {:ok, @valid} == OptionalFields.fetch(@valid)
    end

    test "rejects a concurrency_cap that is not a positive integer" do
      for cap <- ["4", 0, -1, 1.5, 4.0, true] do
        assert {:error, {:invalid_project, {:invalid_concurrency_cap, ^cap}}} =
                 OptionalFields.fetch(%{concurrency_cap: cap})
      end
    end

    test "accepts nil or a positive integer concurrency_cap" do
      assert {:ok, %{concurrency_cap: nil}} = OptionalFields.fetch(%{concurrency_cap: nil})
      assert {:ok, %{concurrency_cap: 1}} = OptionalFields.fetch(%{concurrency_cap: 1})
    end

    test "rejects landing_policy values other than :manual or :auto" do
      assert {:error, {:invalid_project, {:invalid_landing_policy, "auto"}}} =
               OptionalFields.fetch(%{landing_policy: "auto"})

      assert {:error, {:invalid_project, {:invalid_landing_policy, nil}}} =
               OptionalFields.fetch(%{landing_policy: nil})
    end

    test "rejects a non-binary target_branch" do
      assert {:error, {:invalid_project, {:invalid_target_branch, :main}}} =
               OptionalFields.fetch(%{target_branch: :main})
    end

    test "rejects a non-atom reviewer" do
      assert {:error, {:invalid_project, {:invalid_reviewer, "codex"}}} =
               OptionalFields.fetch(%{reviewer: "codex"})
    end

    test "rejects a pollution_allowlist that is not nil or a list of strings" do
      assert {:error, {:invalid_project, {:invalid_pollution_allowlist, "scratch.txt"}}} =
               OptionalFields.fetch(%{pollution_allowlist: "scratch.txt"})

      assert {:error, {:invalid_project, {:invalid_pollution_allowlist, [:scratch]}}} =
               OptionalFields.fetch(%{pollution_allowlist: [:scratch]})
    end

    test "rejects warm_paths that are not a list of strings" do
      assert {:error, {:invalid_project, {:invalid_warm_paths, "priv/foo"}}} =
               OptionalFields.fetch(%{warm_paths: "priv/foo"})

      assert {:error, {:invalid_project, {:invalid_warm_paths, nil}}} =
               OptionalFields.fetch(%{warm_paths: nil})
    end

    test "accepts test_db_isolation_env nil, false, :none, or a string" do
      for value <- [nil, false, :none, "MIX_TEST_PARTITION"] do
        assert {:ok, %{test_db_isolation_env: ^value}} =
                 OptionalFields.fetch(%{test_db_isolation_env: value})
      end
    end

    test "rejects an invalid test_db_isolation_env" do
      assert {:error, {:invalid_project, {:invalid_test_db_isolation_env, :partition}}} =
               OptionalFields.fetch(%{test_db_isolation_env: :partition})
    end

    test "rejects tooling_baseline_overrides that are not a string-to-string map" do
      assert {:error, {:invalid_project, {:invalid_tooling_baseline_overrides, %{foo: "bar"}}}} =
               OptionalFields.fetch(%{tooling_baseline_overrides: %{foo: "bar"}})

      assert {:error, {:invalid_project, {:invalid_tooling_baseline_overrides, nil}}} =
               OptionalFields.fetch(%{tooling_baseline_overrides: nil})
    end
  end

  describe "validate/1" do
    test "accepts a project whose optional fields match the struct type" do
      project = %Project{
        name: "ok",
        source: {:local, "/tmp/ok"},
        roadmap_path: "/tmp/ok",
        languages: [:elixir],
        concurrency_cap: 4
      }

      assert :ok = OptionalFields.validate(project)
    end

    test "rejects a project whose concurrency_cap is a string" do
      project = %Project{
        name: "bad",
        source: {:local, "/tmp/bad"},
        roadmap_path: "/tmp/bad",
        languages: [:elixir],
        concurrency_cap: "4"
      }

      assert {:error, {:invalid_project, {:invalid_concurrency_cap, "4"}}} =
               OptionalFields.validate(project)
    end
  end
end
