alias Harness.ResultStore.Memory

# The default test result store is shared by the suite; start from an empty
# in-memory scope so stale records from prior runs cannot poison history reads.
with {Memory, opts} <- Application.get_env(:harness, :result_store) do
  Memory.reset(opts)
end

# The dashboard Endpoint isn't in the test supervision tree (`:dashboard
# enabled: false`), but Phoenix.LiveViewTest needs it started to serve config
# and mount the dashboard LiveViews. Harness.PubSub is already up via the app
# boot; start the Endpoint here (server: false in config — no port bind).
{:ok, _} =
  Supervisor.start_link([Harness.Dashboard.Endpoint],
    strategy: :one_for_one,
    name: Harness.Test.EndpointSup
  )

ExUnit.start()

# Integration tests drive real external agent CLIs (e.g. `claude`) — slow,
# networked, and not present in every environment. Excluded by default; run them
# with `mix test --include integration`.
ExUnit.configure(exclude: [:integration])
