alias Ecto.Adapters.SQL.Sandbox
alias Harness.Audit.QAAttempt
alias Harness.ProjectFixture
alias Harness.ProjectRegistry
alias Harness.Repo

if Mix.env() != :test, do: raise("QA browser fixtures require MIX_ENV=test")
if Application.get_env(:harness, :repo_enabled), do: raise("QA browser fixtures require isolated persistence")

root = System.fetch_env!("QA_BROWSER_ROOT")
repo = Path.join(root, "repo")
origin = Path.join(root, "origin")
File.mkdir_p!(repo)

for args <- [
      ["init", "--bare", "--initial-branch=main", origin],
      ["-C", repo, "init", "--initial-branch=main"],
      ["-C", repo, "config", "user.email", "qa-browser@example.test"],
      ["-C", repo, "config", "user.name", "QA browser fixture"],
      ["-C", repo, "commit", "--allow-empty", "-m", "browser fixture"],
      ["-C", repo, "remote", "add", "origin", origin],
      ["-C", repo, "push", "-u", "origin", "main"]
    ] do
  {_, 0} = System.cmd("git", args, stderr_to_stdout: true)
end

{:ok, _} = Supervisor.start_link([Repo], strategy: :one_for_one)
owner = Sandbox.start_owner!(Repo, shared: true)

{:ok, _} =
  Oban.start_link(
    name: Harness.Oban,
    repo: Repo,
    testing: :manual,
    queues: false,
    plugins: false,
    notifier: Oban.Notifiers.Isolated
  )

{revision, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])
revision = String.trim(revision)

project = %{
  ProjectFixture.from_repo(repo, name: "qa-browser", target_branch: "main", check_command: "mix check.dispatch")
  | qa_command: "mix precommit.full"
}

:ok = ProjectRegistry.register(project)
:ok = ProjectRegistry.register(%{project | name: "qa-unconfigured", qa_command: nil})

Repo.insert!(%QAAttempt{
  project_name: project.name,
  target_branch: "main",
  command: project.qa_command,
  base_sha: revision,
  revision: revision,
  status: "incomplete",
  agent: "codex",
  model: "gpt-6-astra",
  report: %{
    "qa" => %{
      "report" => "The suite completed; coverage could not run because a tool is unavailable.",
      "evidence" => "Controlled browser fixture. Full-QA evidence remains incomplete.",
      "checks" => [%{"name" => "suite", "status" => "passed"}, %{"name" => "coverage", "status" => "incomplete"}]
    }
  },
  transcript: String.duplicate("Bounded transcript evidence.\n", 400)
})

endpoint = Harness.Dashboard.Endpoint
port = String.to_integer(System.fetch_env!("QA_BROWSER_PORT"))
config = Application.get_env(:harness, endpoint, [])

Application.put_env(
  :harness,
  endpoint,
  Keyword.merge(config, url: [host: "127.0.0.1", port: port], server: true, http: [ip: {127, 0, 0, 1}, port: port])
)

{:ok, _} = Supervisor.start_link([endpoint], strategy: :one_for_one)
IO.puts("QA_BROWSER_READY")
IO.gets("")

Sandbox.stop_owner(owner)
