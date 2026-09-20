alias Harness.Dashboard.RunFeed

# Invoked by inbox.mjs in an isolated test BEAM with memory-only facts.
if Mix.env() != :test, do: raise("Inbox browser fixtures require MIX_ENV=test")
if Application.get_env(:harness, :repo_enabled), do: raise("Inbox browser fixtures require memory storage")

project = Harness.ProjectFixture.from_repo("/tmp/inbox-browser-fixture", name: "browser-fixture")
{:parked, pending} = Harness.Cron.PendingDispatch.park(project.name, "388", Harness.AgentAdapter.Codex, %{})
{:ok, pending} = {:ok, pending}

facts = %{
  projects: [project],
  tasks: %{},
  records: [],
  live_runs: [],
  pending: [pending],
  queued_tasks: %{},
  landing_branches: %{}
}

{:ok, source} = Agent.start_link(fn -> facts end)
Application.put_env(:harness, :inbox_facts, fn -> {:ok, Agent.get(source, & &1)} end)

Application.put_env(:harness, :inbox_action, fn :approve, _row ->
  Agent.update(source, &%{&1 | pending: []})
  {:ok, %{run_id: "browser-approved"}}
end)

endpoint = Harness.Dashboard.Endpoint
port = "INBOX_BROWSER_PORT" |> System.fetch_env!() |> String.to_integer()
config = Application.get_env(:harness, endpoint, [])

Application.put_env(
  :harness,
  endpoint,
  Keyword.merge(config, url: [host: "127.0.0.1", port: port], server: true, http: [ip: {127, 0, 0, 1}, port: port])
)

{:ok, _} = Supervisor.start_link([endpoint], strategy: :one_for_one)
IO.puts("INBOX_BROWSER_READY")

fn -> IO.gets("") end
|> Stream.repeatedly()
|> Enum.reduce_while(nil, fn
  :eof, _ ->
    {:halt, nil}

  "populate\n", _ ->
    Agent.update(source, fn _ -> facts end)
    Phoenix.PubSub.broadcast(Harness.PubSub, RunFeed.topic(), :inbox_changed)
    {:cont, nil}

  "error\n", _ ->
    Application.put_env(:harness, :inbox_facts, fn -> {:error, :fixture_store_unavailable} end)
    Phoenix.PubSub.broadcast(Harness.PubSub, RunFeed.topic(), :inbox_changed)
    {:cont, nil}
end)
