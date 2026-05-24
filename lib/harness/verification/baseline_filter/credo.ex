defmodule Harness.Verification.BaselineFilter.Credo do
  @moduledoc """
  Diff-aware post-processor for the `mix credo --strict` check.

  When the verification stack runs against a worktree dispatched from a
  `:base_ref` (the resolved `Harness.Worktree.base_sha`), this filter
  re-grades the credo result: TagTODO findings whose `# TODO` already existed
  in the dispatch base are dropped as inherited debt, not failures. A
  dispatched agent is then only graded on TODOs *they* introduced — debt
  carried over by, e.g., an `audit(...)` follow-up marker the dispatch base
  inherited does not red the run.

  The filter:

    * is a no-op when the check already passed, when no `:base_ref` is given,
      or when the worktree is not a git working tree;
    * re-runs `mix credo --strict --format json` to get structured issues,
      then drops TagTODO findings at `(file, line)` pairs in the baseline set;
    * re-grades the result to `:pass` iff *all* remaining issues are filtered
      away — any non-TagTODO finding or any TagTODO that did not pre-exist
      leaves the original `:fail` verdict intact.

  Defensive by design: any git error, JSON parse failure, or unexpected shape
  returns the input result unchanged so the original pass/fail signal is
  preserved.

  ## Pure vs I/O

  The pure re-grading logic — `filter_issues/3` and `regrade/3` — is exposed
  for unit testing without needing to shell out to a Mix project; the public
  entry point `apply/2` wires the I/O (credo invocation + git grep) around
  those pure functions.
  """

  alias Harness.Git
  alias Harness.Verification.Result

  @tagtodo_check "Credo.Check.Design.TagTODO"
  @todo_pattern ~r/#\s*TODO/

  @typedoc "A `{relative_path, line_no}` pair flagged as a TODO in the dispatch base."
  @type baseline :: MapSet.t({String.t(), pos_integer()})

  @doc """
  Re-grades a credo `Harness.Verification.Result` against the baseline ref.

  Returns the result unchanged unless it can prove every remaining credo
  finding is a pre-existing TagTODO; in that case it returns a `:pass`
  result with an explanatory `[harness]` line appended to the captured
  output.
  """
  @spec apply(Result.t(), keyword()) :: Result.t()
  def apply(%Result{status: :pass} = result, _opts), do: result

  def apply(%Result{} = result, opts) do
    worktree_path = Keyword.get(opts, :worktree_path)
    base_ref = Keyword.get(opts, :base_ref)

    with true <- is_binary(worktree_path) and is_binary(base_ref),
         {:ok, issues} <- credo_issues(worktree_path),
         {:ok, baseline} <- baseline_tagtodo_lines(worktree_path, base_ref) do
      filtered = filter_issues(issues, baseline, worktree_path)
      regrade(result, issues, filtered)
    else
      _ -> result
    end
  end

  @doc """
  Drops every TagTODO issue whose `(file, line)` is in `baseline`.

  Pure: takes a list of credo-formatted issue maps, a baseline set, and the
  absolute worktree path (used to relativize credo's absolute paths to match
  git-grep's repo-relative paths). Returns the remaining issues — empty when
  every finding was inherited.
  """
  @spec filter_issues([map()], baseline(), String.t()) :: [map()]
  def filter_issues(issues, baseline, worktree_path) do
    Enum.reject(issues, &baseline_tagtodo?(&1, baseline, worktree_path))
  end

  @doc """
  Re-grades `result` based on the original issues list and the post-filter list.

  Pure: emits a `:pass` Result when every issue was filtered, an annotated
  `:fail` Result when only some were, and the input Result unchanged when
  the filter dropped nothing.
  """
  @spec regrade(Result.t(), [map()], [map()]) :: Result.t()
  def regrade(%Result{} = result, _issues, []) do
    %{
      result
      | status: :pass,
        output:
          result.output <>
            "\n[harness] credo: all findings were pre-existing TagTODOs from the dispatch base; re-graded :pass"
    }
  end

  def regrade(%Result{} = result, issues, filtered) when length(filtered) < length(issues) do
    dropped = length(issues) - length(filtered)

    %{
      result
      | output:
          result.output <>
            "\n[harness] credo: #{dropped} pre-existing TagTODO finding(s) were filtered; #{length(filtered)} finding(s) remain — verdict stays :fail"
    }
  end

  def regrade(%Result{} = result, _issues, _filtered), do: result

  @doc """
  Builds the set of `{relative_path, line_no}` pairs where the file at
  `base_ref` has a `# TODO` comment.

  `git grep` with a tree-ish argument walks the index of that ref, so the
  working tree's current content is irrelevant — exactly the "what already
  existed?" question we need to ask. Returns `:error` on any git failure
  except "no matches" (which is a legitimate empty baseline).
  """
  @spec baseline_tagtodo_lines(String.t(), String.t()) :: {:ok, baseline()} | :error
  def baseline_tagtodo_lines(worktree_path, base_ref) do
    case Git.run(["grep", "-n", "-I", "-E", Regex.source(@todo_pattern), base_ref], worktree_path) do
      {:ok, output} ->
        {:ok, parse_git_grep(output)}

      # `git grep` exits 1 when there are no matches — the baseline has no
      # TODOs, so the filter has nothing to drop. Empty set, not an error.
      {:error, {:git_failed, _args, 1, ""}} ->
        {:ok, MapSet.new()}

      {:error, _reason} ->
        :error
    end
  end

  # Runs `mix credo --strict --format json` in the worktree, returning the
  # parsed `issues` list. Defensive: any non-zero startup error / parse failure
  # short-circuits to `:error` so `apply/2` keeps the original red verdict.
  # The argument vector is a fixed list of literals — `worktree_path` flows
  # only through the `:cd` option, never as a shell-interpolable argument.
  # sobelow_skip ["CI.System"]
  @spec credo_issues(String.t()) :: {:ok, [map()]} | :error
  defp credo_issues(worktree_path) do
    case System.find_executable("mix") do
      nil ->
        :error

      mix ->
        {output, _status} =
          System.cmd(mix, ["credo", "--strict", "--format", "json"],
            cd: worktree_path,
            stderr_to_stdout: true
          )

        parse_credo_issues(output)
    end
  end

  # Credo's `--format json` prefixes the JSON document with mix compile noise;
  # locate the JSON body by scanning for the leading `{` and parsing from there.
  @spec parse_credo_issues(String.t()) :: {:ok, [map()]} | :error
  defp parse_credo_issues(output) do
    with {:ok, json} <- locate_json(output),
         {:ok, %{"issues" => issues}} when is_list(issues) <- Jason.decode(json) do
      {:ok, issues}
    else
      _ -> :error
    end
  end

  @spec locate_json(String.t()) :: {:ok, String.t()} | :error
  defp locate_json(output) do
    case :binary.match(output, "{") do
      :nomatch -> :error
      {pos, _len} -> {:ok, binary_part(output, pos, byte_size(output) - pos)}
    end
  end

  # `git grep <ref>` emits `<ref>:<path>:<line>:<content>` per match. The
  # `<ref>:` prefix is constant for one invocation — split each line on the
  # first three colons, take the file and line.
  @spec parse_git_grep(String.t()) :: baseline()
  defp parse_git_grep(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_grep_line/1)
    |> MapSet.new()
  end

  @spec parse_grep_line(String.t()) :: [{String.t(), pos_integer()}]
  defp parse_grep_line(line) do
    with [_ref, file, line_no, _content] <- String.split(line, ":", parts: 4),
         {n, ""} when n > 0 <- Integer.parse(line_no) do
      [{file, n}]
    else
      _ -> []
    end
  end

  @spec baseline_tagtodo?(map(), baseline(), String.t()) :: boolean()
  defp baseline_tagtodo?(
         %{"check" => @tagtodo_check, "filename" => filename, "line_no" => line_no},
         baseline,
         worktree_path
       )
       when is_binary(filename) and is_integer(line_no) do
    relative = relativize(filename, worktree_path)
    MapSet.member?(baseline, {relative, line_no})
  end

  defp baseline_tagtodo?(_issue, _baseline, _worktree_path), do: false

  # Credo emits absolute file paths (`/abs/path/to/worktree/lib/foo.ex`);
  # `git grep` emits paths relative to the repo root (`lib/foo.ex`). Strip
  # the worktree-path prefix to align them.
  @spec relativize(String.t(), String.t()) :: String.t()
  defp relativize(filename, worktree_path) do
    Path.relative_to(filename, worktree_path)
  end
end
