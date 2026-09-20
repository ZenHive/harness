alias Harness.Maintenance.Store

if Mix.env() != :test, do: raise("Maintenance browser fixtures require MIX_ENV=test")
if Application.get_env(:harness, :repo_enabled), do: raise("Browser fixtures require isolated memory storage")

:ok =
  Harness.ProjectRegistry.register(Harness.ProjectFixture.from_repo("/tmp/maintenance-browser", name: "browser-fixture"))

finding = %{
  "id" => "browser-finding",
  "project" => "browser-fixture",
  "title" => "Reduce repeated query work",
  "category" => "performance",
  "evidence" => "Controlled browser fixture. Baseline 40ms; comparable after measurement unavailable.",
  "rationale" => "Retain until comparable evidence is available.",
  "improvement" => "Avoid repeated lookup while preserving behavior.",
  "outcome" => "Unverified",
  "blocked" => true,
  "at" => "2026-09-20T12:00:00Z",
  "source_revision" => String.duplicate("a", 40),
  "agent" => "codex",
  "model" => "gpt-6-astra"
}

:ok =
  Store.put_many([
    {"finding/browser-finding", "finding/browser-fixture", finding},
    {"revision/browser-finding/1", "revision/browser-finding", finding}
  ])

endpoint = Harness.Dashboard.Endpoint
port = String.to_integer(System.fetch_env!("MAINTENANCE_BROWSER_PORT"))
config = Application.get_env(:harness, endpoint, [])

Application.put_env(
  :harness,
  endpoint,
  Keyword.merge(config, url: [host: "127.0.0.1", port: port], server: true, http: [ip: {127, 0, 0, 1}, port: port])
)

{:ok, _} = Supervisor.start_link([endpoint], strategy: :one_for_one)
IO.puts("MAINTENANCE_BROWSER_READY")
IO.gets("")
