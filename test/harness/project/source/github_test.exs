defmodule Harness.Project.Source.GithubTest do
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.GithubFixture
  alias Harness.Project
  alias Harness.Project.Source.Github

  describe "url/1" do
    test "returns the URL from a github-source project" do
      project = build_project("demo", "https://github.com/octocat/Hello-World.git")
      assert Github.url(project) == "https://github.com/octocat/Hello-World.git"
    end
  end

  describe "local_path/2" do
    test "joins the cache root with the project's name" do
      project = build_project("demo", "https://example.invalid/r.git")
      cache_root = GitFixture.tmp_base(name: "cache")

      assert Github.local_path(project, cache_root: cache_root) ==
               Path.join(cache_root, "demo")
    end

    test "expands the configured cache root with a leading ~" do
      project = build_project("demo", "https://example.invalid/r.git")

      assert Github.local_path(project, cache_root: "~/_DATA/harness/projects") ==
               Path.join(Path.expand("~/_DATA/harness/projects"), "demo")
    end

    test "does not touch the filesystem" do
      project = build_project("ghost", "https://example.invalid/r.git")
      cache_root = GitFixture.tmp_base(name: "cache")

      path = Github.local_path(project, cache_root: cache_root)

      refute File.exists?(path)
    end
  end

  describe "ensure_local/2 — first clone" do
    test "clones the upstream into <cache_root>/<name> when the cache is empty" do
      upstream = GithubFixture.init_upstream(name: "ensure-clone")
      project = fixture_project("ensure-clone", upstream)
      cache_root = GitFixture.tmp_base(name: "cache")

      assert {:ok, path} = Github.ensure_local(project, cache_root: cache_root)

      assert path == Path.join(cache_root, "ensure-clone")
      assert File.dir?(Path.join(path, ".git"))
      assert File.read!(Path.join(path, "README.md")) == "harness git fixture\n"
    end

    test "creates the cache_root parent directory if missing" do
      upstream = GithubFixture.init_upstream(name: "mkdir-parent")
      project = fixture_project("mkdir-parent", upstream)
      tmp = GitFixture.tmp_base(name: "missing-cache")
      nested_cache = Path.join([tmp, "nested", "cache"])

      assert {:ok, path} = Github.ensure_local(project, cache_root: nested_cache)

      assert File.dir?(path)
    end

    test "clones an scp-style git URL" do
      upstream = GithubFixture.init_upstream(name: "scp-clone")
      prefix = "git@harness-fixture-#{System.unique_integer([:positive])}.invalid:"
      project = build_project("scp-clone", allowed_fixture_url(upstream.bare_path, prefix))
      cache_root = GitFixture.tmp_base(name: "cache")

      assert {:ok, path} = Github.ensure_local(project, cache_root: cache_root)
      assert File.dir?(Path.join(path, ".git"))
    end

    test "surfaces a clone failure when the URL is unreachable" do
      bogus = Path.join(System.tmp_dir!(), "harness-not-a-repo-#{System.unique_integer([:positive])}")
      project = build_project("bogus", allowed_fixture_url(bogus))
      cache_root = GitFixture.tmp_base(name: "cache")

      assert {:error, {:clone_failed, status, output}} =
               Github.ensure_local(project, cache_root: cache_root)

      assert status != 0
      assert is_binary(output)
    end

    test "uses the configured application cache root with the default arity" do
      upstream = GithubFixture.init_upstream(name: "configured-cache")
      cache_root = GitFixture.tmp_base(name: "configured-cache-root")
      previous = Application.fetch_env(:harness, :project)
      Application.put_env(:harness, :project, cache_root: cache_root)

      on_exit(fn -> restore_project_config(previous) end)

      assert {:ok, path} = Github.ensure_local(fixture_project("configured-cache", upstream))
      assert path == Path.join(cache_root, "configured-cache")
    end

    test "returns mkdir_failed when the cache root is a file" do
      upstream = GithubFixture.init_upstream(name: "mkdir-failure")
      cache_root = GitFixture.tmp_base(name: "cache-root-file")
      File.write!(cache_root, "not a directory")

      assert {:error, {:mkdir_failed, ^cache_root, :enotdir}} =
               Github.ensure_local(fixture_project("mkdir-failure", upstream), cache_root: cache_root)
    end
  end

  describe "ensure_local/2 — subsequent fetch" do
    test "fast-forwards the local default branch to upstream after fetch" do
      upstream = GithubFixture.init_upstream(name: "fetch-ff")
      project = fixture_project("fetch-ff", upstream)
      cache_root = GitFixture.tmp_base(name: "cache")

      {:ok, path} = Github.ensure_local(project, cache_root: cache_root)
      initial_sha = String.trim(GitFixture.git!(path, ["rev-parse", "HEAD"]))

      GithubFixture.push_commit(upstream, file: "new.txt", content: "added later\n")
      upstream_sha = String.trim(GitFixture.git!(upstream.bare_path, ["rev-parse", "main"]))

      assert {:ok, ^path} = Github.ensure_local(project, cache_root: cache_root)

      new_sha = String.trim(GitFixture.git!(path, ["rev-parse", "refs/heads/main"]))
      assert new_sha != initial_sha
      assert new_sha == upstream_sha
    end

    test "is a no-op against an upstream that has not advanced" do
      upstream = GithubFixture.init_upstream(name: "fetch-noop")
      project = fixture_project("fetch-noop", upstream)
      cache_root = GitFixture.tmp_base(name: "cache")

      {:ok, path} = Github.ensure_local(project, cache_root: cache_root)
      sha_before = String.trim(GitFixture.git!(path, ["rev-parse", "refs/heads/main"]))

      assert {:ok, ^path} = Github.ensure_local(project, cache_root: cache_root)
      sha_after = String.trim(GitFixture.git!(path, ["rev-parse", "refs/heads/main"]))

      assert sha_after == sha_before
    end

    test "returns fetch_failed when the cached origin is unreachable" do
      upstream = GithubFixture.init_upstream(name: "fetch-failure")
      project = fixture_project("fetch-failure", upstream)
      cache_root = GitFixture.tmp_base(name: "cache")
      {:ok, path} = Github.ensure_local(project, cache_root: cache_root)
      missing = Path.join(cache_root, "missing-origin")
      GitFixture.git!(path, ["remote", "set-url", "origin", missing])

      assert {:error, {:fetch_failed, _reason}} = Github.ensure_local(project, cache_root: cache_root)
    end

    test "returns fast_forward_failed when the local branch ref is locked" do
      upstream = GithubFixture.init_upstream(name: "fast-forward-failure")
      project = fixture_project("fast-forward-failure", upstream)
      cache_root = GitFixture.tmp_base(name: "cache")
      {:ok, path} = Github.ensure_local(project, cache_root: cache_root)
      File.write!(Path.join([path, ".git", "refs", "heads", "main.lock"]), "locked")

      assert {:error, {:fast_forward_failed, _reason}} = Github.ensure_local(project, cache_root: cache_root)
    end

    test "returns default_branch_lookup_failed when HEAD is detached" do
      upstream = GithubFixture.init_upstream(name: "detached-head")
      project = fixture_project("detached-head", upstream)
      cache_root = GitFixture.tmp_base(name: "cache")
      {:ok, path} = Github.ensure_local(project, cache_root: cache_root)
      GitFixture.git!(path, ["checkout", "--detach"])

      assert {:error, {:default_branch_lookup_failed, _reason}} =
               Github.ensure_local(project, cache_root: cache_root)
    end
  end

  describe "ensure_local/2 — cache recovery" do
    test "transparently re-clones when the cache directory was removed" do
      upstream = GithubFixture.init_upstream(name: "recovery")
      project = fixture_project("recovery", upstream)
      cache_root = GitFixture.tmp_base(name: "cache")

      {:ok, path} = Github.ensure_local(project, cache_root: cache_root)
      assert File.dir?(path)
      File.rm_rf!(path)
      refute File.dir?(path)

      assert {:ok, ^path} = Github.ensure_local(project, cache_root: cache_root)

      assert File.dir?(Path.join(path, ".git"))
      assert File.read!(Path.join(path, "README.md")) == "harness git fixture\n"
    end
  end

  describe "ensure_local/2 — URL validation" do
    test "rejects ext transport URLs before invoking git" do
      cache_root = GitFixture.tmp_base(name: "ext-url-cache")
      project = build_project("ext-url", "ext::sh -c echo exploit %S")

      assert {:error, {:invalid_url, :unsupported_scheme}} =
               Github.ensure_local(project, cache_root: cache_root)

      refute File.exists?(cache_root)
    end

    test "rejects leading-dash URLs before invoking git" do
      cache_root = GitFixture.tmp_base(name: "dash-url-cache")
      project = build_project("dash-url", "--upload-pack=malicious")

      assert {:error, {:invalid_url, :leading_dash}} =
               Github.ensure_local(project, cache_root: cache_root)

      refute File.exists?(cache_root)
    end
  end

  defp build_project(name, url) do
    %Project{
      name: name,
      source: {:github, url},
      roadmap_path: "/tmp/#{name}",
      languages: [:elixir]
    }
  end

  defp fixture_project(name, upstream), do: build_project(name, allowed_fixture_url(upstream.bare_path))

  defp allowed_fixture_url(path) do
    fixture_prefix = "https://harness-fixture.invalid/#{System.unique_integer([:positive])}/"
    allowed_fixture_url(path, fixture_prefix)
  end

  defp allowed_fixture_url(path, fixture_prefix) do
    local_prefix = "file://#{Path.dirname(path)}/"
    env_keys = ~w(GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0)
    previous = Map.new(env_keys, &{&1, System.get_env(&1)})

    System.put_env("GIT_CONFIG_COUNT", "1")
    System.put_env("GIT_CONFIG_KEY_0", "url.#{local_prefix}.insteadOf")
    System.put_env("GIT_CONFIG_VALUE_0", fixture_prefix)
    on_exit(fn -> restore_env(previous) end)

    fixture_prefix <> Path.basename(path)
  end

  defp restore_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_project_config({:ok, value}), do: Application.put_env(:harness, :project, value)
  defp restore_project_config(:error), do: Application.delete_env(:harness, :project)
end
