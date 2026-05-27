defmodule Harness.GithubFixture do
  @moduledoc false

  # Test scaffolding for the GitHub-source suite: spins up a local bare git
  # repository that stands in for a GitHub upstream. `git clone <bare-path>`
  # works the same as cloning from a real URL — the Source.Github
  # implementation does not validate that the URL is on github.com.

  alias Harness.GitFixture

  @spec init_upstream(keyword()) :: %{bare_path: String.t(), working_path: String.t()}
  def init_upstream(opts \\ []) do
    name = Keyword.get(opts, :name, "upstream")
    working = GitFixture.init_repo(name: name <> "-source")

    bare = unique_tmp_dir(name <> "-bare") <> ".git"

    case System.cmd("git", ["clone", "--quiet", "--bare", working, bare], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "git clone --bare failed (#{status}):\n#{output}"
    end

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(bare) end)

    %{bare_path: bare, working_path: working}
  end

  @spec push_commit(map(), keyword()) :: :ok
  def push_commit(upstream, opts) do
    file = Keyword.fetch!(opts, :file)
    content = Keyword.fetch!(opts, :content)
    message = Keyword.get(opts, :message, "add #{file}")
    working = upstream.working_path

    File.write!(Path.join(working, file), content)
    GitFixture.git!(working, ["add", file])
    GitFixture.git!(working, ["commit", "-q", "-m", message])
    GitFixture.git!(working, ["push", "--quiet", upstream.bare_path, "main"])
    :ok
  end

  @spec unique_tmp_dir(String.t()) :: String.t()
  defp unique_tmp_dir(name) do
    # See `Harness.GitFixture.unique_tmp_dir/1` — the nanosecond suffix keeps
    # the path unique across BEAM restarts, since `System.unique_integer/1`
    # resets to 1 and would otherwise collide with leftovers in `/tmp`.
    suffix = "#{System.unique_integer([:positive])}-#{System.os_time(:nanosecond)}"
    Path.join(System.tmp_dir!(), "harness-#{name}-#{suffix}")
  end
end
