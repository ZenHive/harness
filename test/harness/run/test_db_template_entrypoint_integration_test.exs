defmodule Harness.Run.TestDbTemplateEntrypointIntegrationTest do
  use ExUnit.Case, async: false

  alias Harness.Run.TestDbTemplate

  @moduletag :integration

  defmodule Repo do
    @moduledoc false
    use Ecto.Repo, otp_app: :harness, adapter: Ecto.Adapters.Postgres
  end

  setup do
    socket =
      System.get_env("HARNESS_TEMPLATE_TEST_SOCKET") ||
        flunk("Export HARNESS_TEMPLATE_TEST_SOCKET for the disposable PostgreSQL cluster in docs/test-db-templates.md.")

    run_id = "entrypoint-#{System.unique_integer([:positive])}"

    recipe = %{
      "repo" => inspect(Repo),
      "database" => "entrypoint_test",
      "template" => "harness_test_template_probe",
      "extensions" => ["vector", "postgis"]
    }

    config = [
      socket_dir: socket,
      port: 55_422,
      username: "template_runner",
      database: "entrypoint_test" <> TestDbTemplate.partition(run_id)
    ]

    old_repos = Application.fetch_env(:harness, :ecto_repos)
    old_config = Application.fetch_env(:harness, Repo)
    Application.put_env(:harness, :ecto_repos, [Repo])
    Application.put_env(:harness, Repo, config)

    on_exit(fn ->
      restore(:ecto_repos, old_repos)
      restore(Repo, old_config)
      assert :ok = TestDbTemplate.drop(recipe, config, run_id)
    end)

    %{recipe: recipe, config: config, run_id: run_id}
  end

  test "entrypoint validates effective Ecto configuration and supports both operations", ctx do
    assert :ok = TestDbTemplate.run!(ctx.recipe, ctx.run_id, :prepare)
    assert_raise Mix.Error, ~r/already exists/, fn -> TestDbTemplate.run!(ctx.recipe, ctx.run_id, :prepare) end
    assert :ok = TestDbTemplate.run!(ctx.recipe, ctx.run_id, :drop)

    assert_raise Mix.Error, ~r/exactly the configured/, fn ->
      TestDbTemplate.run!(%{ctx.recipe | "repo" => "Other.Repo"}, ctx.run_id, :prepare)
    end

    Application.put_env(:harness, :ecto_repos, [Repo, Other.Repo])
    assert_raise Mix.Error, ~r/exactly the configured/, fn -> TestDbTemplate.run!(ctx.recipe, ctx.run_id, :prepare) end
  end

  test "unreachable PostgreSQL is explicit setup evidence", ctx do
    config = Keyword.put(ctx.config, :port, 55423)
    assert {:error, evidence} = TestDbTemplate.prepare(ctx.recipe, config, ctx.run_id)
    assert evidence =~ "PostgreSQL connection failed"
    assert evidence =~ "docs/test-db-templates.md"
  end

  @spec restore(atom(), {:ok, term()} | :error) :: :ok
  defp restore(key, {:ok, value}), do: Application.put_env(:harness, key, value)
  defp restore(key, :error), do: Application.delete_env(:harness, key)
end
