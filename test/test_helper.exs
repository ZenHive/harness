# The file-backed test result store (config.exs: $TMPDIR/harness_results_test) is
# shared by every test run and never expires records — stale records from prior
# runs poison StatusView/dashboard history reads and grow unbounded. Start each
# suite from an empty store. Only an explicitly configured root is wiped, so a
# misconfiguration can never point this at the real ~/.harness store.
with {Harness.ResultStore.File, opts} <- Application.get_env(:harness, :result_store),
     root when is_binary(root) <- Keyword.get(opts, :root) do
  File.rm_rf!(root)
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
