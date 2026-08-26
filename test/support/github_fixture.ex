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

    bare = GitFixture.unique_tmp_dir(name <> "-bare") <> ".git"

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

  @doc """
  Returns a clone URL for `bare_path` that passes `Source.Github`'s scheme
  allowlist.

  Task 403 restricted `{:github, url}` sources to http(s)/ssh/git/scp forms, so a
  bare local path is no longer accepted. Git's `url.<base>.insteadOf` rewrite lets
  a fixture keep a real local upstream behind an allowlisted `https://` address.
  The rewrite is installed through `GIT_CONFIG_*`, which is process-global — every
  suite using this helper must be `async: false`.
  """
  @spec allowlisted_url(String.t()) :: String.t()
  def allowlisted_url(bare_path) do
    allowlisted_url(bare_path, "https://harness-fixture.invalid/#{System.unique_integer([:positive])}/")
  end

  @doc "Same as `allowlisted_url/1` with a caller-chosen allowlisted prefix (e.g. an scp-style address)."
  @spec allowlisted_url(String.t(), String.t()) :: String.t()
  def allowlisted_url(bare_path, fixture_prefix) do
    local_prefix = "file://#{Path.dirname(bare_path)}/"
    env_keys = ~w(GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0)
    previous = Map.new(env_keys, &{&1, System.get_env(&1)})

    System.put_env("GIT_CONFIG_COUNT", "1")
    System.put_env("GIT_CONFIG_KEY_0", "url.#{local_prefix}.insteadOf")
    System.put_env("GIT_CONFIG_VALUE_0", fixture_prefix)
    ExUnit.Callbacks.on_exit(fn -> restore_env(previous) end)

    fixture_prefix <> Path.basename(bare_path)
  end

  @spec restore_env(%{String.t() => String.t() | nil}) :: :ok
  defp restore_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end
end
