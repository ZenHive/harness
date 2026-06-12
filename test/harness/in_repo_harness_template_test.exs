defmodule Harness.InRepoHarnessTemplateTest do
  use ExUnit.Case, async: true

  alias Harness.InRepoTemplate

  @rust_fixture Path.expand("../support/fixtures/rust_project", __DIR__)
  @harness_repo_root Path.expand("../..", __DIR__)

  test "template copies verbatim, boots Harness.Application, and registers one local project" do
    repo_root = fixture_repo_root!()
    harness_dir = Path.join(repo_root, "harness")

    InRepoTemplate.copy!(harness_dir)
    patch_mix_exs_for_path_dep!(harness_dir)

    assert mix_succeeds!(harness_dir, ["deps.get"])
    assert mix_succeeds!(harness_dir, ["compile"])

    output =
      mix_succeeds!(
        harness_dir,
        [
          "run",
          "--no-start",
          "-e",
          boot_and_dump_script()
        ]
      )

    dump_path =
      output
      |> String.split("\n", trim: true)
      |> Enum.find(&String.ends_with?(&1, ".term"))

    assert dump_path

    assert %{
             name: "app",
             source: {:local, source},
             check_command: "cargo " <> _
           } = dump_path |> File.read!() |> :erlang.binary_to_term()

    assert same_dir?(source, repo_root)

    on_exit(fn -> File.rm(dump_path) end)
  end

  test "template dir contains the canonical scaffold files" do
    root = InRepoTemplate.dir()

    for path <- [
          "mix.exs",
          "config/config.exs",
          "config/runtime.exs",
          "lib/project_harness.ex",
          "roadmap/tasks.toml",
          ".gitignore"
        ] do
      assert File.regular?(Path.join(root, path)), "missing template file #{path}"
    end
  end

  defp fixture_repo_root! do
    dest = Path.join(System.tmp_dir!(), "in_repo_harness_#{System.unique_integer([:positive])}")
    File.cp_r!(@rust_fixture, dest)
    on_exit(fn -> File.rm_rf!(dest) end)
    dest
  end

  defp patch_mix_exs_for_path_dep!(harness_dir) do
    mix_path = Path.join(harness_dir, "mix.exs")

    mix_path
    |> File.read!()
    |> String.replace("{:harness, \"~> 0.1\"}", "{:harness, path: #{inspect(@harness_repo_root)}}")
    |> then(&File.write!(mix_path, &1))
  end

  defp mix_succeeds!(harness_dir, args) do
    {output, status} =
      System.cmd("mix", args,
        cd: harness_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, "mix #{Enum.join(args, " ")} failed (#{status}):\n#{output}"
    output
  end

  defp same_dir?(left, right) do
    {:ok, left_stat} = File.stat(left)
    {:ok, right_stat} = File.stat(right)
    left_stat.inode == right_stat.inode
  end

  defp boot_and_dump_script do
    ~s"""
    {:ok, _} = Application.ensure_all_started(:project_harness)
    [project] = Harness.ProjectRegistry.list()
    data = %{
      name: project.name,
      source: project.source,
      check_command: project.check_command
    }
    path = Path.join(System.tmp_dir!(), "in_repo_boot_#{System.unique_integer([:positive])}.term")
    :ok = File.write!(path, :erlang.term_to_binary(data))
    IO.puts(path)
    """
  end
end
