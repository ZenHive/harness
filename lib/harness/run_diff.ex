defmodule Harness.RunDiff do
  @moduledoc """
  Read-only reconstruction of a settled run's git diff for the dashboard.

  Every run commits its work to a `harness/<run_id>` branch that worktree
  teardown leaves intact (`Harness.Worktree.remove/1` deletes only the working
  directory). So a settled run's change set is always recoverable from git on
  demand — no diff is persisted into the `Harness.Run.LogRecord`.

  `for_run/2` resolves the project's on-disk repo **read-only** (via
  `Harness.Project.repo_path/2` — never `ensure_local_repo/2`, which would clone
  or fetch), then reads the aggregate diff of the run branch against its fork
  point with a single `git diff <base>...<branch>` (three-dot: merge-base →
  branch tip). The three-dot range captures every commit on the branch —
  including each repair attempt — without needing a stored base SHA.

  The raw patch is parsed into fully render-ready structure (`t:t/0`): a per-file
  list, each file carrying its status, +/- counts, and classified lines. The
  dashboard component (`Harness.Dashboard.Components.run_diff_view/1`) maps that
  structure straight onto styled spans, so all git-porcelain parsing lives here
  where it is unit-tested rather than in HEEx.

  ## Bounded

  The patch is capped at `#{80_000}` bytes (head-truncated — a diff reads
  top-down, so the first files are the signal) with a trailing-codepoint repair,
  mirroring the semantic-diff cap in `Harness.Run`. `truncated: true` flags a
  capped result.

  ## Failure modes

    * `:unknown_project` — no project registered under that name (or `nil`).
    * `:repo_unavailable` — the resolved repo path is missing or not a git tree
      (e.g. a `{:github, _}` source never cloned in this BEAM).
    * `:branch_absent` — `harness/<run_id>` no longer exists (the autonomous
      lander merged + deleted it, or it was never created). Rendered as a
      graceful "diff no longer available" note, never a crash.
    * `{:git_failed, _, _, _}` — an unexpected git invocation failure.
  """

  alias Harness.Git
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Text

  @branch_prefix "harness/"
  @patch_cap_bytes 80_000

  @typedoc "How a file changed in the run diff."
  @type status :: :added | :modified | :deleted | :renamed

  @typedoc "How one patch line is classified for rendering."
  @type line_kind :: :hunk | :add | :del | :ctx | :meta

  @typedoc "One classified patch line, ready to render as a styled span."
  @type line :: %{kind: line_kind(), text: String.t()}

  @typedoc "One changed file with its counts and classified lines."
  @type file :: %{
          path: String.t(),
          old_path: String.t() | nil,
          status: status(),
          added: non_neg_integer(),
          deleted: non_neg_integer(),
          binary: boolean(),
          lines: [line()]
        }

  @typedoc "A reconstructed run diff."
  @type t :: %{
          branch: String.t(),
          files: [file()],
          added: non_neg_integer(),
          deleted: non_neg_integer(),
          truncated: boolean()
        }

  @typedoc "Why a run diff could not be produced."
  @type reason :: :unknown_project | :repo_unavailable | :branch_absent | Git.error()

  @doc """
  Reconstructs the aggregate git diff for `run_id` in the project named
  `project_name`.

  Returns `{:ok, t()}` or `{:error, reason()}` (see the moduledoc). A `nil`
  project name (a record persisted before the field existed) resolves to
  `{:error, :unknown_project}`.
  """
  @spec for_run(String.t(), String.t() | nil) :: {:ok, t()} | {:error, reason()}
  def for_run(run_id, project_name) when is_binary(run_id) and is_binary(project_name) do
    branch = @branch_prefix <> run_id

    with {:ok, project} <- lookup(project_name),
         repo = Project.repo_path(project),
         :ok <- ensure_repo(repo),
         :ok <- ensure_branch(repo, branch),
         {:ok, raw} <- raw_diff(repo, branch) do
      {capped, truncated?} = cap(raw)
      {:ok, summarize(branch, parse(capped), truncated?)}
    end
  end

  # A nil project_name (record persisted before the field existed) or any
  # non-binary input resolves to :unknown_project rather than crashing.
  def for_run(_run_id, _project_name), do: {:error, :unknown_project}

  # ── Repo / branch resolution ──────────────────────────────────────────────

  @spec lookup(String.t()) :: {:ok, Project.t()} | {:error, :unknown_project}
  defp lookup(project_name) do
    case ProjectRegistry.lookup(project_name) do
      {:ok, project} -> {:ok, project}
      {:error, _reason} -> {:error, :unknown_project}
    end
  end

  @spec ensure_repo(String.t()) :: :ok | {:error, :repo_unavailable}
  defp ensure_repo(repo) do
    if File.dir?(repo) and Git.work_tree?(repo), do: :ok, else: {:error, :repo_unavailable}
  end

  # `rev-parse --verify --quiet <branch>^{commit}` exits non-zero with no output
  # when the branch is gone — Git.run surfaces that as {:git_failed, …}, which we
  # normalize to the dedicated :branch_absent reason the UI renders gracefully.
  @spec ensure_branch(String.t(), String.t()) :: :ok | {:error, :branch_absent}
  defp ensure_branch(repo, branch) do
    case Git.run(["rev-parse", "--verify", "--quiet", branch <> "^{commit}"], repo) do
      {:ok, _sha} -> :ok
      {:error, _reason} -> {:error, :branch_absent}
    end
  end

  # Three-dot: diff from merge-base(HEAD, branch) to the branch tip — i.e. every
  # change the run introduced on its branch, across all repair commits, relative
  # to where it forked from the repo's current HEAD. No stored base SHA needed.
  @spec raw_diff(String.t(), String.t()) :: {:ok, String.t()} | {:error, Git.error()}
  defp raw_diff(repo, branch) do
    Git.run(["diff", "--no-ext-diff", "--no-color", "--find-renames", "HEAD...#{branch}"], repo)
  end

  # ── Patch parsing ─────────────────────────────────────────────────────────

  @spec parse(String.t()) :: [file()]
  defp parse(patch) do
    patch
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.reduce([], &reduce_line/2)
    |> Enum.reverse()
    |> Enum.map(fn file -> %{file | lines: Enum.reverse(file.lines)} end)
  end

  # A `diff --git a/<old> b/<new>` line opens a new file accumulator (head of the
  # list). Every subsequent line is classified and prepended onto it until the
  # next `diff --git`. Lines before the first header (none in well-formed output)
  # are dropped.
  @spec reduce_line(String.t(), [file()]) :: [file()]
  defp reduce_line("diff --git " <> rest, files) do
    {_old, new} = parse_git_header(rest)

    file = %{
      path: new,
      old_path: nil,
      status: :modified,
      added: 0,
      deleted: 0,
      binary: false,
      lines: [%{kind: :meta, text: "diff --git " <> rest}]
    }

    [file | files]
  end

  defp reduce_line(_line, []), do: []

  defp reduce_line(line, [current | rest]) do
    [classify(line, current) | rest]
  end

  # Status-bearing + structural meta lines are matched before the generic +/-
  # content classification (so `+++`/`---` file headers are never miscounted as
  # added/deleted content lines).
  @spec classify(String.t(), file()) :: file()
  defp classify("new file mode" <> _ = line, file), do: meta(%{file | status: :added}, line)
  defp classify("deleted file mode" <> _ = line, file), do: meta(%{file | status: :deleted}, line)
  defp classify("rename from " <> old = line, file), do: meta(%{file | status: :renamed, old_path: old}, line)
  defp classify("rename to " <> _ = line, file), do: meta(%{file | status: :renamed}, line)

  defp classify("Binary files " <> _ = line, file), do: meta(%{file | binary: true}, line)

  defp classify("@@" <> _ = line, file), do: add_line(file, :hunk, line)

  defp classify("+++ " <> _ = line, file), do: meta(file, line)
  defp classify("--- " <> _ = line, file), do: meta(file, line)

  defp classify("+" <> _ = line, file) do
    %{add_line(file, :add, line) | added: file.added + 1}
  end

  defp classify("-" <> _ = line, file) do
    %{add_line(file, :del, line) | deleted: file.deleted + 1}
  end

  # `index …`, `old/new mode`, `similarity …`, `\ No newline …`, and the leading
  # space of context lines all fall through here. A blank line inside a hunk is
  # context too.
  defp classify(line, file) do
    if structural_meta?(line), do: meta(file, line), else: add_line(file, :ctx, line)
  end

  @spec structural_meta?(String.t()) :: boolean()
  defp structural_meta?(line) do
    String.starts_with?(line, [
      "index ",
      "old mode",
      "new mode",
      "similarity ",
      "dissimilarity ",
      "copy from ",
      "copy to ",
      "\\ No newline"
    ])
  end

  @spec meta(file(), String.t()) :: file()
  defp meta(file, line), do: add_line(file, :meta, line)

  @spec add_line(file(), line_kind(), String.t()) :: file()
  defp add_line(file, kind, text) do
    %{file | lines: [%{kind: kind, text: text} | file.lines]}
  end

  # `a/<old> b/<new>` — split on the ` b/` boundary, then strip the `a/` prefix.
  # Best-effort: pathological names (spaces around ` b/`, embedded newlines) are
  # out of scope and degrade to a single combined path rather than crashing.
  @spec parse_git_header(String.t()) :: {String.t(), String.t()}
  defp parse_git_header(rest) do
    case String.split(rest, " b/", parts: 2) do
      [a_part, new] -> {String.replace_prefix(a_part, "a/", ""), new}
      [single] -> {single, single}
    end
  end

  # ── Capping + summary ─────────────────────────────────────────────────────

  # Head-truncate (a diff is read top-down) and repair a codepoint split at the
  # cut so the kept slice is always valid UTF-8.
  @spec cap(String.t()) :: {String.t(), boolean()}
  defp cap(patch) when byte_size(patch) <= @patch_cap_bytes, do: {patch, false}

  defp cap(patch) do
    {Text.valid_utf8_head(binary_part(patch, 0, @patch_cap_bytes)), true}
  end

  @spec summarize(String.t(), [file()], boolean()) :: t()
  defp summarize(branch, files, truncated?) do
    %{
      branch: branch,
      files: files,
      added: Enum.reduce(files, 0, &(&1.added + &2)),
      deleted: Enum.reduce(files, 0, &(&1.deleted + &2)),
      truncated: truncated?
    }
  end
end
