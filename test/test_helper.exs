alias Harness.GitFixture
alias Harness.ResultStore.Memory
alias Harness.Test.SettingsStoreMemory

fixture_root =
  Path.join(
    System.tmp_dir!(),
    "harness-test-fixtures-#{System.pid()}-#{System.os_time(:nanosecond)}"
  )

Application.put_env(:harness, :test_fixture_root, fixture_root)

# The default test result store is shared by the suite; start from an empty
# in-memory scope so stale records from prior runs cannot poison history reads.
with {Memory, opts} <- Application.get_env(:harness, :result_store) do
  Memory.reset(opts)
end

# Same for the in-memory settings store: create (and own) its ETS table here, in
# the suite-lifetime test_helper process, so it survives the whole run. Created
# lazily by a transient per-test process instead, the table would be destroyed
# when that process dies mid-suite — silently dropping another test's just-written
# flip and making every settings-survives-restart test intermittently fail.
with {SettingsStoreMemory, opts} <- Application.get_env(:harness, :settings_store) do
  SettingsStoreMemory.reset(opts)
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
ExUnit.after_suite(&GitFixture.cleanup_suite_root(fixture_root, &1))

# Integration tests drive real external agent CLIs (e.g. `claude`) — slow,
# networked, and not present in every environment. Excluded by default; run them
# with `mix test --include integration`.
ExUnit.configure(exclude: [:integration])
