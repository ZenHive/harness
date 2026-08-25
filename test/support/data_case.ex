defmodule Harness.DataCase do
  @moduledoc """
  Test case template for Postgres-backed integration tests (Task 137).

  Starts the Repo under the test supervisor and checks out a SQL Sandbox
  connection in :shared mode (required because Oban producers and other
  harness-supervised processes run in separate processes).

  Usage: `use Harness.DataCase, async: false` + `@moduletag :integration`

  Requires a migrated test DB: `MIX_ENV=test mix ecto.create ecto.migrate`
  Run the tagged suite with `mix test.json --include integration`.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Ecto
      import Ecto.Query
      import Harness.DataCase

      alias Harness.Repo
    end
  end

  setup tags do
    # Always start a fresh supervised Repo for this test (test env has
    # repo_enabled: false so the normal supervision tree omits it).
    start_supervised!(Harness.Repo)
    Sandbox.checkout(Harness.Repo)

    # Share the connection with any processes the test may start
    # (e.g. Oban, ResultStore.Postgres calls from other tasks).
    if !tags[:async] do
      Sandbox.mode(Harness.Repo, {:shared, self()})
    end

    Harness.SettingsStore.reset_cache()
    on_exit(fn -> Harness.SettingsStore.reset_cache() end)

    :ok
  end
end
