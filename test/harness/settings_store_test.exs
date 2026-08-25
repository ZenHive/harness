defmodule Harness.SettingsStoreTest.BlockingStore do
  @moduledoc false
  @behaviour Harness.SettingsStore

  alias Harness.Test.SettingsStoreMemory

  @impl Harness.SettingsStore
  @spec fetch(String.t(), keyword()) :: {:ok, term()} | :not_found
  def fetch(key, backend_opts) when is_binary(key) and is_list(backend_opts) do
    snapshot = SettingsStoreMemory.fetch(key, Keyword.delete(backend_opts, :owner))

    case Keyword.get(backend_opts, :owner) do
      pid when is_pid(pid) -> send(pid, {:fetch_started, self(), key})
      _ -> :ok
    end

    receive do
      :continue -> snapshot
    after
      2_000 -> snapshot
    end
  end

  @impl Harness.SettingsStore
  @spec put(String.t(), term(), keyword()) :: :ok
  def put(key, value, backend_opts) when is_binary(key) and is_list(backend_opts) do
    SettingsStoreMemory.put(key, value, Keyword.delete(backend_opts, :owner))
  end
end

defmodule Harness.SettingsStoreTest.CountingStore do
  @moduledoc false
  @behaviour Harness.SettingsStore

  alias Harness.Test.SettingsStoreMemory

  @impl Harness.SettingsStore
  @spec fetch(String.t(), keyword()) :: {:ok, term()} | :not_found
  def fetch(key, backend_opts) when is_binary(key) and is_list(backend_opts) do
    count(backend_opts, {:fetch, key})
    SettingsStoreMemory.fetch(key, Keyword.delete(backend_opts, :owner))
  end

  @impl Harness.SettingsStore
  @spec put(String.t(), term(), keyword()) :: :ok
  def put(key, value, backend_opts) when is_binary(key) and is_list(backend_opts) do
    count(backend_opts, {:put, key})
    SettingsStoreMemory.put(key, value, Keyword.delete(backend_opts, :owner))
  end

  @spec count(keyword(), term()) :: term()
  defp count(backend_opts, message) do
    case Keyword.get(backend_opts, :owner) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end

defmodule Harness.SettingsStoreTest do
  # async: false because tests mutate global repo/settings application env.
  use ExUnit.Case, async: false

  alias Harness.SettingsStore
  alias Harness.SettingsStore.Schema.Setting
  alias Harness.SettingsStoreTest.BlockingStore
  alias Harness.SettingsStoreTest.CountingStore
  alias Harness.Test.SettingsStoreMemory

  setup do
    prior = %{
      repo_enabled: Application.get_env(:harness, :repo_enabled),
      settings_store: Application.get_env(:harness, :settings_store)
    }

    on_exit(fn -> restore_env(prior) end)

    :ok
  end

  describe "configured/0" do
    test "picks Postgres when repo_enabled and no override" do
      Application.put_env(:harness, :repo_enabled, true)
      Application.delete_env(:harness, :settings_store)

      assert {Harness.SettingsStore.Postgres, []} = SettingsStore.configured()
    end

    test "is the ephemeral no-op store when repo_enabled is false" do
      Application.put_env(:harness, :repo_enabled, false)
      Application.delete_env(:harness, :settings_store)

      assert SettingsStore.configured() == false
    end

    test "respects an explicit settings_store override" do
      Application.put_env(:harness, :settings_store, false)

      assert SettingsStore.configured() == false
    end
  end

  describe "ephemeral (false) store" do
    test "fetch is :not_found and put is a discarded :ok" do
      Application.put_env(:harness, :settings_store, false)

      assert :ok = SettingsStore.put(:agent, %{disabled: [:pi]})
      assert :not_found = SettingsStore.fetch(:agent)
      assert :not_found = SettingsStore.fetch("agent")
    end

    test "does not serve a cached value written while a real backend was configured" do
      scope = unique_scope("ephemeral-isolation")
      Application.put_env(:harness, :settings_store, {SettingsStoreMemory, scope: scope})
      on_exit(fn -> SettingsStoreMemory.reset(scope: scope) end)

      assert :ok = SettingsStore.put(:agent, %{disabled: [:pi]})
      assert {:ok, %{disabled: [:pi]}} = SettingsStore.fetch(:agent)

      Application.put_env(:harness, :settings_store, false)
      assert :not_found = SettingsStore.fetch(:agent)
      assert :ok = SettingsStore.put(:agent, %{disabled: [:codex]})
      assert :not_found = SettingsStore.fetch(:agent)
    end
  end

  describe "round-trip through a backend" do
    test "put then fetch returns the value (atom or binary key)" do
      scope = unique_scope("round-trip")
      Application.put_env(:harness, :settings_store, {SettingsStoreMemory, scope: scope})
      on_exit(fn -> SettingsStoreMemory.reset(scope: scope) end)

      record = %{disabled: [:codex]}
      assert :ok = SettingsStore.put(:agent, record)
      assert {:ok, ^record} = SettingsStore.fetch(:agent)
      assert {:ok, ^record} = SettingsStore.fetch("agent")
    end
  end

  describe "missing rows" do
    test "returns :not_found when no row exists for the key" do
      scope = unique_scope("no-legacy")
      on_exit(fn -> SettingsStoreMemory.reset(scope: scope) end)

      Application.put_env(:harness, :settings_store, {SettingsStoreMemory, scope: scope})

      assert :not_found = SettingsStore.fetch(:landing)
    end
  end

  describe "write-through cache" do
    test "put is visible to the very next fetch without a second backend read" do
      scope = unique_scope("write-through")
      owner = self()
      Application.put_env(:harness, :settings_store, {CountingStore, scope: scope, owner: owner})
      on_exit(fn -> SettingsStoreMemory.reset(scope: scope) end)

      record = %{disabled: [:cursor]}
      assert :ok = SettingsStore.put(:agent, record)
      assert [{:put, "agent"}] = drain_backend()

      assert {:ok, ^record} = SettingsStore.fetch(:agent)
      assert [] = drain_backend()
    end

    test "repeated fetches of the same key hit the backend once" do
      scope = unique_scope("read-coalesce")
      owner = self()
      Application.put_env(:harness, :settings_store, {CountingStore, scope: scope, owner: owner})
      on_exit(fn -> SettingsStoreMemory.reset(scope: scope) end)

      assert :not_found = SettingsStore.fetch(:landing)
      assert :not_found = SettingsStore.fetch(:landing)
      assert :not_found = SettingsStore.fetch("landing")
      assert [{:fetch, "landing"}] = drain_backend()
    end

    test "put overwrites a previously cached miss" do
      scope = unique_scope("overwrite-miss")
      owner = self()
      Application.put_env(:harness, :settings_store, {CountingStore, scope: scope, owner: owner})
      on_exit(fn -> SettingsStoreMemory.reset(scope: scope) end)

      assert :not_found = SettingsStore.fetch(:agent)
      assert [{:fetch, "agent"}] = drain_backend()

      record = %{disabled: [:pi]}
      assert :ok = SettingsStore.put(:agent, record)
      assert [{:put, "agent"}] = drain_backend()

      assert {:ok, ^record} = SettingsStore.fetch(:agent)
      assert [] = drain_backend()
    end

    test "an in-flight fetch cannot clobber a put that already returned" do
      scope = unique_scope("inflight-put")
      owner = self()
      Application.put_env(:harness, :settings_store, {BlockingStore, scope: scope, owner: owner})
      on_exit(fn -> SettingsStoreMemory.reset(scope: scope) end)

      task = Task.async(fn -> SettingsStore.fetch(:agent) end)
      assert_receive {:fetch_started, fetch_pid, "agent"}

      record = %{disabled: [:cursor]}
      assert :ok = SettingsStore.put(:agent, record)
      assert {:ok, ^record} = SettingsStore.fetch(:agent)

      send(fetch_pid, :continue)
      assert {:ok, ^record} = Task.await(task)
      assert {:ok, ^record} = SettingsStore.fetch(:agent)
    end
  end

  test "Setting changeset accepts key and payload attrs" do
    attrs = %{key: "cron", payload: :erlang.term_to_binary(%{master_enabled: false})}

    assert %{valid?: true} = Setting.changeset(%Setting{}, attrs)
  end

  defp unique_scope(label), do: :"settings_store_#{label}_#{System.unique_integer([:positive])}"

  defp drain_backend(acc \\ []) do
    receive do
      {:fetch, _} = message -> drain_backend([message | acc])
      {:put, _} = message -> drain_backend([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp restore_env(prior) do
    Enum.each(prior, fn
      {key, nil} -> Application.delete_env(:harness, key)
      {key, value} -> Application.put_env(:harness, key, value)
    end)
  end
end
