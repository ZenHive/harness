defmodule Harness.ProjectCache.CopyCancellationTest do
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.ProjectCache
  alias Harness.ProjectFixture
  alias Harness.Worktree

  for operation <- [:remove, :retain, :crash_cleanup] do
    @operation operation
    test "#{operation} waits for a cancelled preparation copy to finish cleanup" do
      repo = GitFixture.init_repo()
      File.write!(Path.join(repo, ".gitignore"), "deps/\n")
      GitFixture.git!(repo, ["add", ".gitignore"])
      GitFixture.git!(repo, ["commit", "-qm", "ignore cache"])
      base = GitFixture.tmp_base()
      cache = GitFixture.tmp_base()
      bin = GitFixture.tmp_base()
      File.mkdir_p!(bin)
      ready = Path.join(bin, "ready")
      release = Path.join(bin, "release")
      assert {_, 0} = System.cmd("mkfifo", [release])
      cp = System.find_executable("cp")

      File.write!(Path.join(bin, "cp"), """
      #!/bin/sh
      case "$*" in
        *cache-seed-*) printf ready > "$COPY_READY"; read permit < "$COPY_RELEASE" ;;
      esac
      exec #{cp} "$@"
      """)

      File.chmod!(Path.join(bin, "cp"), 0o755)
      original = System.fetch_env!("PATH")
      env = Map.take(System.get_env(), ["COPY_READY", "COPY_RELEASE"])
      System.put_env(%{"PATH" => bin <> ":" <> original, "COPY_READY" => ready, "COPY_RELEASE" => release})

      on_exit(fn ->
        System.put_env("PATH", original)

        for key <- ["COPY_READY", "COPY_RELEASE"] do
          if value = env[key], do: System.put_env(key, value), else: System.delete_env(key)
        end
      end)

      {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base)

      recipe = %{
        "commands" => ["mkdir deps; printf bytes > deps/value"],
        "paths" => ["deps"],
        "identity_commands" => ["printf tool"]
      }

      caller = Task.async(fn -> ProjectCache.prepare(wt, recipe, cache_root: cache) end)
      await_ready(ready)
      Task.shutdown(caller, :brutal_kill)

      finishing =
        Task.async(fn ->
          case @operation do
            :remove -> Worktree.finish(wt, :failure, retain_on_failure: false)
            :retain -> Worktree.finish(wt, :failure, retain_on_failure: true)
            :crash_cleanup -> Worktree.cleanup_for_run(repo, wt.id)
          end
        end)

      ref = finishing.ref
      refute_receive {^ref, _}, 100
      assert {_, 0} = System.cmd("sh", ["-c", "printf release > \"$1\"", "release", release])
      assert :ok = Task.await(finishing, 5000)
      refute File.exists?(Path.join(wt.path, "deps"))
      assert Path.wildcard(Path.join(wt.path, ".harness/cache-seed-*")) == []
      assert Path.wildcard(Path.join(cache, "*.building-*")) == []
      if @operation == :retain, do: assert(Worktree.retained?(wt.path)), else: refute(File.exists?(wt.path))
    end
  end

  defp await_ready(path, attempts \\ 500)
  defp await_ready(_path, 0), do: flunk("copy did not reach barrier")

  defp await_ready(path, attempts) do
    if File.exists?(path),
      do: :ok,
      else:
        (receive do
         after
           10 -> await_ready(path, attempts - 1)
         end)
  end
end
