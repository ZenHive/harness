defmodule Harness.ProjectCache.CommandTest do
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.ProjectCache.Command

  test "identity hashes cover all output bytes while command diagnostics stay bounded" do
    owner = Process.monitor(self())
    deadline = System.monotonic_time(:millisecond) + 5000
    suffix = "head -c 70000 /dev/zero | tr '\\0' x"
    assert {:ok, a} = Command.run("printf first; " <> suffix, System.tmp_dir!(), %{}, owner, deadline, :digest)
    assert {:ok, b} = Command.run("printf other; " <> suffix, System.tmp_dir!(), %{}, owner, deadline, :digest)
    assert a != b
    assert a == :crypto.hash(:sha256, "first" <> String.duplicate("x", 70_000))
    assert {:ok, output} = Command.run(suffix, System.tmp_dir!(), %{}, owner, deadline)
    assert byte_size(output) == 65_536
  end

  test "missing host executable and child executable report mechanical failures" do
    owner = Process.monitor(self())
    deadline = System.monotonic_time(:millisecond) + 5000

    assert {:error, {:command_start_exit, 127}} =
             Command.run("true", System.tmp_dir!(), %{"PATH" => "/nonexistent"}, owner, deadline)

    original = System.fetch_env!("PATH")
    on_exit(fn -> System.put_env("PATH", original) end)

    try do
      System.put_env("PATH", "/nonexistent")
      assert {:error, {:missing_executable, "setsid"}} = Command.run("true", System.tmp_dir!(), %{}, owner, deadline)
    after
      System.put_env("PATH", original)
    end
  end

  test "missing cwd and expired deadline fail explicitly" do
    owner = Process.monitor(self())
    missing = Path.join(GitFixture.tmp_base(), "missing")

    assert {:error, {:command_start_exit, 2}} =
             Command.run("true", missing, %{}, owner, System.monotonic_time(:millisecond) + 5000)

    assert {:error, :timeout} = Command.check(owner, System.monotonic_time(:millisecond) - 1)
  end

  test "declared environment inputs omit unrelated shell variables but invalidate on build variables" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    root = GitFixture.tmp_base()
    File.write!(Path.join(repo, ".gitignore"), "deps/\n")
    GitFixture.git!(repo, ["add", ".gitignore"])
    GitFixture.git!(repo, ["commit", "-qm", "ignore artifacts"])
    project = Harness.ProjectFixture.from_repo(repo)

    recipe = %{
      "commands" => ["mkdir deps"],
      "paths" => ["deps"],
      "identity_commands" => ["printf tool"],
      "env_inputs" => ["CACHE_TEST_BUILD"]
    }

    original = System.get_env("CACHE_TEST_SHELL")
    build = System.get_env("CACHE_TEST_BUILD")

    on_exit(fn ->
      restore_env("CACHE_TEST_SHELL", original)
      restore_env("CACHE_TEST_BUILD", build)
    end)

    try do
      {:ok, one} = Harness.Worktree.create(project, base_dir: base)
      assert {:ok, a} = Harness.ProjectCache.prepare(one, recipe, cache_root: root)
      System.put_env("CACHE_TEST_SHELL", "another-pane")
      {:ok, two} = Harness.Worktree.create(project, base_dir: base)
      assert {:ok, %{state: :hit, key: key}} = Harness.ProjectCache.prepare(two, recipe, cache_root: root)
      assert key == a.key
      System.put_env("CACHE_TEST_BUILD", "new-flavor")
      {:ok, three} = Harness.Worktree.create(project, base_dir: base)
      assert {:ok, %{state: :built, key: changed}} = Harness.ProjectCache.prepare(three, recipe, cache_root: root)
      assert changed != key
    after
      restore_env("CACHE_TEST_SHELL", original)
      restore_env("CACHE_TEST_BUILD", build)
    end
  end

  test "a command cannot inherit environment values added after the snapshot" do
    key = "CACHE_TEST_LATE_ENV"
    original = System.get_env(key)
    on_exit(fn -> restore_env(key, original) end)
    snapshot = Map.delete(System.get_env(), key)
    owner = Process.monitor(self())

    try do
      System.put_env(key, "late-setting")

      assert {:ok, "unset"} =
               Command.run(
                 "printf '%s' \"${CACHE_TEST_LATE_ENV-unset}\"",
                 System.tmp_dir!(),
                 snapshot,
                 owner,
                 System.monotonic_time(:millisecond) + 5000
               )
    after
      restore_env(key, original)
    end
  end

  test "an external held lock times out without executing the protected operation" do
    base = GitFixture.tmp_base()
    File.mkdir_p!(base)
    lock = Path.join(base, "lock")

    holder =
      Port.open({:spawn_executable, System.find_executable("flock")}, [
        :binary,
        :exit_status,
        args: ["-x", lock, "sh", "-c", "printf held; cat >/dev/null"]
      ])

    assert_receive {^holder, {:data, "held"}}, 5000
    owner = Process.monitor(self())

    try do
      assert {:error, :timeout} =
               Command.locked(lock, owner, System.monotonic_time(:millisecond) + 50, fn -> flunk("lock was bypassed") end)
    after
      Port.close(holder)
    end
  end

  test "startup honors short deadlines and owner cancellation before running user code" do
    base = GitFixture.tmp_base()
    File.mkdir_p!(base)
    fifo = Path.join(base, "start")
    ready = Path.join(base, "ready")
    assert {_, 0} = System.cmd("mkfifo", [fifo])
    wrapper = Path.join(base, "setsid")
    File.write!(wrapper, ~s(#!/bin/sh\nprintf ready > "$READY"\nread permit < "$FIFO"\n))
    File.chmod!(wrapper, 0o755)
    original = System.fetch_env!("PATH")
    on_exit(fn -> System.put_env("PATH", original) end)
    System.put_env("PATH", base <> ":" <> original)

    try do
      for mode <- [:timeout, :cancel] do
        File.rm(ready)

        owner =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        task =
          Task.async(fn ->
            ref = Process.monitor(owner)
            budget = if mode == :timeout, do: 100, else: 5000

            Command.run(
              "touch must-not-run",
              base,
              %{"READY" => ready, "FIFO" => fifo},
              ref,
              System.monotonic_time(:millisecond) + budget
            )
          end)

        await_ready(ready)
        if mode == :cancel, do: send(owner, :stop)
        expected = if mode == :timeout, do: :timeout, else: :interrupted
        assert {:error, ^expected} = Task.await(task, 500)
        send(owner, :stop)
        refute File.exists?(Path.join(base, "must-not-run"))
      end
    after
      System.put_env("PATH", original)
    end
  end

  defp await_ready(path, attempts \\ 500)
  defp await_ready(_path, 0), do: flunk("startup did not reach barrier")

  defp await_ready(path, attempts) do
    if File.exists?(path),
      do: :ok,
      else:
        (receive do
         after
           10 -> await_ready(path, attempts - 1)
         end)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
