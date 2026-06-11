defmodule Harness.Repo.MigrationGuardTest do
  @moduledoc """
  Unit tests for the fail-fast pending-migration check. `check!/1` takes the
  `Ecto.Migrator.migrations/1` status list directly, so these need no DB.
  """
  use ExUnit.Case, async: true

  alias Harness.Repo.MigrationGuard

  describe "check!/1" do
    test "returns :ok when no migrations are pending" do
      assert :ok = MigrationGuard.check!([])

      assert :ok =
               MigrationGuard.check!([
                 {:up, 20_260_602_141_000, "add_projects"},
                 {:up, 20_260_611_120_000, "add_warm_paths_to_projects"}
               ])
    end

    test "raises naming the pending migration when one is :down" do
      migrations = [
        {:up, 20_260_602_141_000, "add_projects"},
        {:down, 20_260_611_120_000, "add_warm_paths_to_projects"}
      ]

      assert_raise RuntimeError, ~r/pending migration/i, fn ->
        MigrationGuard.check!(migrations)
      end
    end

    test "raise message lists every pending version and the migrate instruction" do
      migrations = [
        {:down, 20_260_611_120_000, "add_warm_paths_to_projects"},
        {:down, 20_260_612_000_000, "add_something_else"}
      ]

      error =
        assert_raise RuntimeError, fn ->
          MigrationGuard.check!(migrations)
        end

      assert error.message =~ "2 pending migration"
      assert error.message =~ "20260611120000 add_warm_paths_to_projects"
      assert error.message =~ "20260612000000 add_something_else"
      assert error.message =~ "mix ecto.migrate"
    end
  end
end
