alias Harness.Insights
alias Harness.Insights.Publication
alias Harness.Insights.Store

# Invoked only by run_insights.mjs under MIX_ENV=test; no database or scheduler.
if Mix.env() != :test, do: raise("Run Insights browser fixtures require MIX_ENV=test")
if Application.get_env(:harness, :repo_enabled), do: raise("Browser fixtures require isolated memory storage")

Application.put_env(:harness, :agent_model, codex: "gpt-6-astra")

:ok =
  Harness.ProjectRegistry.register(
    Harness.ProjectFixture.from_repo("/tmp/insights-browser-fixture", name: "browser-fixture")
  )

endpoint = Harness.Dashboard.Endpoint
config = Application.get_env(:harness, endpoint, [])

Application.put_env(
  :harness,
  endpoint,
  Keyword.merge(config,
    url: [host: "127.0.0.1", port: String.to_integer(System.fetch_env!("INSIGHTS_BROWSER_PORT"))],
    server: true,
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.fetch_env!("INSIGHTS_BROWSER_PORT"))]
  )
)

{:ok, _} = Supervisor.start_link([endpoint], strategy: :one_for_one)
IO.puts("INSIGHTS_BROWSER_READY")

fn -> IO.gets("") end
|> Stream.repeatedly()
|> Enum.reduce_while(nil, fn
  :eof, _ ->
    {:halt, nil}

  "populate\n", _ ->
    source =
      Harness.Insights.Evidence.source(
        "browser-run",
        "browser-fixture",
        "review_report",
        String.duplicate(
          "The reviewer added missing validation for empty input. This evidence is a controlled browser fixture.\n",
          35
        ),
        false
      )

    finding = Harness.Test.InsightsWitness.finding(source)

    {:ok, docs} =
      Publication.prepare(%{"findings" => [finding]}, [source], [], "browser-first", %{
        "agent" => "codex",
        "model" => "gpt-6-astra"
      })

    :ok = Store.put_many(docs)
    [prior] = Insights.findings()["items"]

    revised =
      Map.merge(finding, %{
        "id" => prior["id"],
        "assessment" =>
          "The same validation omission recurred in a later run. The previous merge did not establish resolution."
      })

    {:ok, docs} =
      Publication.prepare(%{"findings" => [revised]}, [source], [prior], "browser-second", %{
        "agent" => "codex",
        "model" => "gpt-6-astra"
      })

    :ok = Store.put_many(docs)
    IO.puts("INSIGHTS_POPULATED #{prior["id"]}")
    {:cont, nil}

  "error\n", _ ->
    :ok =
      Store.put_many([
        {"pass/browser-error", "pass",
         %{
           "id" => "browser-error",
           "state" => "failed",
           "error" => "Selected provider rejected the observation. Check agent availability and observer settings.",
           "at" => DateTime.to_iso8601(DateTime.utc_now())
         }},
        {"settings", "settings", Map.put(Insights.settings(), "enabled", true)}
      ])

    Phoenix.PubSub.broadcast(Harness.PubSub, "harness:insights", :insights_updated)
    IO.puts("INSIGHTS_ERROR_READY")
    {:cont, nil}

  other, _ ->
    raise("Unexpected fixture command: #{inspect(other)}")
end)
