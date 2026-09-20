defmodule Harness.Projects.DispatchQA.HooksTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.Projects.DispatchQA.Hooks

  test "inventory distinguishes installed plugins from stale project references and records exact scripts" do
    home = GitFixture.init_repo()
    root = GitFixture.init_repo()
    install = Path.join(home, "plugin-cache/version-1")
    File.mkdir_p!(Path.join(home, ".claude/plugins"))
    File.mkdir_p!(Path.join(root, ".claude"))
    File.mkdir_p!(Path.join(install, "hooks/scripts"))

    File.write!(
      Path.join(root, ".claude/settings.json"),
      ~s({"enabledPlugins":{"elixir@zenhive":true},"env":{"PRIVATE":"not-in-inventory"}})
    )

    File.write!(
      Path.join(home, ".claude/plugins/installed_plugins.json"),
      Jason.encode!(%{"plugins" => %{"format@installed" => [%{"installPath" => install, "scope" => "user"}]}})
    )

    File.write!(Path.join(install, "hooks/hooks.json"), ~s({"hooks":{"PostToolUse":[]}}))
    script = Path.join(install, "hooks/scripts/format.sh")
    File.write!(script, "#!/bin/sh\necho formatting\n")
    snapshot = Hooks.inventory(home: home, project_root: root)
    assert [%{plugin: "format@installed", files: files}] = snapshot.installed_plugins
    assert Enum.any?(files, &(&1.path == script and &1.content =~ "echo formatting"))
    settings = Enum.find(snapshot.settings, &(&1.path == Path.join(root, ".claude/settings.json")))
    assert settings.settings["enabledPlugins"]["elixir@zenhive"]
    refute Map.has_key?(settings.settings, "env")
    refute File.exists?(Path.join(root, ".claude/settings.local.json"))
    assert File.read!(script) == "#!/bin/sh\necho formatting\n"
  end

  test "captures configured Python and JavaScript files outside plugin caches and follows cyclic imports" do
    home = GitFixture.init_repo()
    root = GitFixture.init_repo()
    File.mkdir_p!(Path.join(home, ".claude/includes"))
    File.mkdir_p!(Path.join(root, ".cursor"))
    script = Path.join(home, "full gate.py")
    javascript = Path.join(root, "verify.js")
    File.write!(script, "print('full QA')")
    File.write!(javascript, "console.log('focused')")

    File.write!(
      Path.join(home, ".claude/settings.json"),
      Jason.encode!(%{
        "hooks" => %{"PostToolUse" => [%{"hooks" => [%{"command" => "python3 \"#{script}\""}]}]}
      })
    )

    File.write!(
      Path.join(root, ".cursor/hooks.json"),
      Jason.encode!(%{
        "hooks" => %{"afterFileEdit" => [%{"command" => "node verify.js"}]}
      })
    )

    File.write!(Path.join(home, ".claude/CLAUDE.md"), "@includes/extra.md")
    File.write!(Path.join(home, ".claude/includes/extra.md"), "@../CLAUDE.md")
    snapshot = Hooks.inventory(home: home, project_root: root)
    sources = Enum.flat_map(snapshot.configured_commands, & &1.sources)
    assert Enum.any?(sources, &(&1.path == script and &1.content == "print('full QA')"))
    assert Enum.any?(sources, &(&1.path == javascript and &1.content == "console.log('focused')"))
    assert Enum.count(snapshot.inherited_instructions, &(&1.path == Path.join(home, ".claude/CLAUDE.md"))) == 1
    assert Enum.any?(snapshot.inherited_instructions, &(&1.path == Path.join(home, ".claude/includes/extra.md")))
  end
end
