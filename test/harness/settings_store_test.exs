defmodule Harness.SettingsStoreTest do
  use ExUnit.Case, async: true

  alias Harness.SettingsStore
  alias Harness.SettingsStore.File, as: FileStore
  alias Harness.SettingsStore.Schema.Setting
  alias Harness.TermCodec

  setup do
    prior = %{
      repo_enabled: Application.get_env(:harness, :repo_enabled),
      settings_store: Application.get_env(:harness, :settings_store),
      agent_settings: Application.get_env(:harness, :agent_settings)
    }

    on_exit(fn ->
      restore_env(prior)
    end)

    :ok
  end

  test "configured/0 picks Postgres when repo_enabled and no override" do
    Application.put_env(:harness, :repo_enabled, true)
    Application.delete_env(:harness, :settings_store)

    assert {Harness.SettingsStore.Postgres, []} = SettingsStore.configured()
  end

  test "configured/0 picks File when repo_enabled is false" do
    Application.put_env(:harness, :repo_enabled, false)
    Application.delete_env(:harness, :settings_store)

    assert {FileStore, []} = SettingsStore.configured()
  end

  test "configured/0 respects an explicit settings_store override" do
    Application.put_env(:harness, :settings_store, false)

    assert SettingsStore.configured() == false
  end

  test "disabled?/1 is true when the legacy config key is false or nil" do
    Application.put_env(:harness, :agent_settings, false)

    assert SettingsStore.disabled?(
             legacy_config_key: :agent_settings,
             legacy_filename: "agent_settings.term",
             default_root: "~/.harness"
           )

    Application.put_env(:harness, :agent_settings, nil)

    assert SettingsStore.disabled?(
             legacy_config_key: :agent_settings,
             legacy_filename: "agent_settings.term",
             default_root: "~/.harness"
           )
  end

  test "fetch/put short-circuit when persistence is disabled" do
    opts = [legacy_config_key: :agent_settings, legacy_filename: "agent_settings.term", default_root: "~/.harness"]
    Application.put_env(:harness, :agent_settings, false)

    assert :not_found = SettingsStore.fetch(:agent, opts)
    assert :ok = SettingsStore.put(:agent, %{disabled: []}, opts)
  end

  test "fetch/put short-circuit when settings_store is false" do
    Application.put_env(:harness, :settings_store, false)
    opts = [legacy_filename: "agent_settings.term", default_root: "~/.harness"]

    assert :not_found = SettingsStore.fetch("agent", opts)
    assert :ok = SettingsStore.put("agent", %{}, opts)
  end

  test "legacy_path/1 and legacy_root/1 without a legacy config key" do
    opts = [legacy_filename: "cron_settings.term", default_root: "/tmp/harness-legacy"]

    assert SettingsStore.legacy_path(opts) == Path.join("/tmp/harness-legacy", "cron_settings.term")
    assert SettingsStore.legacy_root(opts) == "/tmp/harness-legacy"
  end

  test "file_root/2 uses backend root when set" do
    opts = [legacy_config_key: :agent_settings, legacy_filename: "agent_settings.term", default_root: "~/.harness"]
    Application.put_env(:harness, :agent_settings, root: "/tmp/agent-root")

    assert SettingsStore.file_root([root: "/tmp/backend-root"], opts) == "/tmp/backend-root"
  end

  test "file backend returns invalid_settings_file for non-map payloads" do
    root = tmp_root("invalid")
    on_exit(fn -> File.rm_rf(root) end)

    path = Path.join(root, "harness_settings.term")
    File.mkdir_p!(root)
    File.write!(path, :erlang.term_to_binary(:not_a_map))

    backend_opts = [root: root]
    opts = [legacy_config_key: :agent_settings, legacy_filename: "agent_settings.term", default_root: root]

    assert {:error, {:invalid_settings_file, ^path}} =
             FileStore.fetch("agent", opts, backend_opts)
  end

  test "file backend import_legacy returns not_found when legacy file is absent" do
    root = tmp_root("missing")
    on_exit(fn -> File.rm_rf(root) end)

    backend_opts = [root: root]

    opts = [
      legacy_config_key: :agent_settings,
      legacy_filename: "agent_settings.term",
      default_root: root
    ]

    Application.put_env(:harness, :agent_settings, root: root)

    assert :not_found = FileStore.fetch("agent", opts, backend_opts)
  end

  test "legacy_root/1 reads root from a keyword config entry" do
    Application.put_env(:harness, :agent_settings, root: "/custom/agent")

    assert SettingsStore.legacy_root(
             legacy_config_key: :agent_settings,
             legacy_filename: "agent_settings.term",
             default_root: "~/.harness"
           ) == "/custom/agent"
  end

  test "legacy_root/1 falls back to default_root when the legacy config is disabled" do
    Application.put_env(:harness, :agent_settings, false)

    assert SettingsStore.legacy_root(
             legacy_config_key: :agent_settings,
             legacy_filename: "agent_settings.term",
             default_root: "/fallback/root"
           ) == "/fallback/root"
  end

  test "file backend imports a missing key from an existing consolidated map" do
    root = tmp_root("partial-map")
    on_exit(fn -> File.rm_rf(root) end)

    consolidated = Path.join(root, "harness_settings.term")
    legacy = Path.join(root, "landing_settings.term")
    File.mkdir_p!(root)

    assert :ok = TermCodec.write_file(consolidated, %{"agent" => %{disabled: []}})

    landing_record = %{"myproj" => %{landing_policy: :manual, target_branch: "main"}}
    assert :ok = TermCodec.write_file(legacy, landing_record)

    backend_opts = [root: root]

    opts = [
      legacy_config_key: :landing_settings,
      legacy_filename: "landing_settings.term",
      default_root: root
    ]

    Application.put_env(:harness, :landing_settings, root: root)

    assert {:ok, ^landing_record} = FileStore.fetch("landing", opts, backend_opts)
  end

  test "fetch/2 dispatches a bare module backend" do
    root = tmp_root("bare-module")
    on_exit(fn -> File.rm_rf(root) end)

    Application.put_env(:harness, :settings_store, FileStore)
    Application.put_env(:harness, :agent_settings, root: root)

    opts = [legacy_config_key: :agent_settings, legacy_filename: "agent_settings.term", default_root: root]
    record = %{disabled: [:pi]}

    assert :ok = SettingsStore.put(:agent, record, opts)
    assert {:ok, ^record} = SettingsStore.fetch(:agent, opts)
  end

  test "file backend surfaces read errors from TermCodec" do
    root = tmp_root("read-error")
    on_exit(fn -> File.rm_rf(root) end)

    path = Path.join(root, "harness_settings.term")
    File.mkdir_p!(root)
    File.write!(path, "not-a-valid-term")

    backend_opts = [root: root]
    opts = [legacy_config_key: :agent_settings, legacy_filename: "agent_settings.term", default_root: root]
    Application.put_env(:harness, :agent_settings, root: root)

    assert {:error, {:invalid_term_file, ^path}} = FileStore.fetch("agent", opts, backend_opts)
  end

  test "Setting changeset accepts key and payload attrs" do
    attrs = %{key: "cron", payload: :erlang.term_to_binary(%{master_enabled: false})}

    assert %{valid?: true} = Setting.changeset(%Setting{}, attrs)
  end

  test "file backend imports a legacy term file on first fetch" do
    root = tmp_root("legacy-import")
    on_exit(fn -> File.rm_rf(root) end)

    legacy = Path.join(root, "cron_settings.term")
    File.mkdir_p!(root)

    assert :ok =
             TermCodec.write_file(legacy, %{
               master_enabled: true,
               project_autonomy: %{},
               schedule: "0 */2 * * *"
             })

    backend_opts = [root: root]

    opts = [
      legacy_config_key: :cron_settings,
      legacy_filename: "cron_settings.term",
      default_root: root
    ]

    Application.put_env(:harness, :cron_settings, root: root)

    assert {:ok, %{master_enabled: true}} = FileStore.fetch("cron", opts, backend_opts)
    assert File.exists?(Path.join(root, "harness_settings.term"))
  end

  test "normalize_key accepts atoms and binaries through fetch" do
    root = tmp_root("key")
    on_exit(fn -> File.rm_rf(root) end)

    Application.put_env(:harness, :repo_enabled, false)
    Application.delete_env(:harness, :settings_store)
    Application.put_env(:harness, :agent_settings, root: root)

    opts = [legacy_config_key: :agent_settings, legacy_filename: "agent_settings.term", default_root: root]
    record = %{disabled: [:codex]}

    assert :ok = SettingsStore.put(:agent, record, opts)
    assert {:ok, ^record} = SettingsStore.fetch("agent", opts)
  end

  defp tmp_root(label) do
    Path.join(System.tmp_dir!(), "settings_store_#{label}_#{System.unique_integer([:positive])}")
  end

  defp restore_env(prior) do
    Enum.each(prior, fn
      {key, nil} -> Application.delete_env(:harness, key)
      {key, value} -> Application.put_env(:harness, key, value)
    end)
  end
end
