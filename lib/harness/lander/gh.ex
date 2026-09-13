defmodule Harness.Lander.GH do
  @moduledoc """
  Mechanical `gh` CLI wrapper used by `:pr` landing.

  Invoked like `git`: an argument list, combined stdout+stderr, no prose parsing.
  `gh pr create` prints the new PR URL on success (observed from `gh pr create
  --help`); when stdout is not a URL, the URL is taken from
  `gh pr view --json url`. JSON field names are the `gh pr view --json` contract
  (`state`, `mergeCommit`, `mergedAt`, `url`).
  """

  @typedoc "A failed gh invocation."
  @type error ::
          :gh_not_found
          | {:gh_unauthenticated, String.t()}
          | {:gh_failed, args :: [String.t()], status :: integer(), output :: String.t()}

  @type json :: %{optional(String.t()) => term()}

  @doc """
  Creates a pull request with `gh pr create` and returns its URL.
  """
  @spec create_pr(keyword()) :: {:ok, String.t()} | {:error, error()}
  def create_pr(opts) when is_list(opts) do
    repo = Keyword.fetch!(opts, :repo)
    args = create_args(opts)

    case run(args, repo) do
      {:ok, output} -> url_from_create(output, repo, Keyword.fetch!(opts, :head))
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Reads PR facts with `gh pr view --json <fields>`.
  """
  @spec view(String.t(), [String.t()], keyword()) :: {:ok, json()} | {:error, error()}
  def view(selector, fields, opts \\ []) when is_binary(selector) and is_list(fields) and is_list(opts) do
    repo = Keyword.get(opts, :repo)
    args = ["pr", "view", selector, "--json", Enum.join(fields, ",")]

    case run(args, repo) do
      {:ok, output} -> decode_json(output)
      {:error, _reason} = error -> error
    end
  end

  @spec create_args(keyword()) :: [String.t()]
  defp create_args(opts) do
    [
      "pr",
      "create",
      "--base",
      Keyword.fetch!(opts, :base),
      "--head",
      Keyword.fetch!(opts, :head),
      "--title",
      Keyword.fetch!(opts, :title),
      "--body",
      Keyword.fetch!(opts, :body)
    ]
  end

  @spec url_from_create(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  defp url_from_create(output, repo, head) do
    case url_line(output) do
      {:ok, url} -> {:ok, url}
      :error -> view_url(repo, head)
    end
  end

  @spec url_line(String.t()) :: {:ok, String.t()} | :error
  defp url_line(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(:error, &url_or_skip/1)
  end

  @spec url_or_skip(String.t()) :: {:ok, String.t()} | nil
  defp url_or_skip(line) do
    trimmed = String.trim(line)
    if String.starts_with?(trimmed, "http"), do: {:ok, trimmed}
  end

  @spec view_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  defp view_url(repo, head) do
    case view(head, ["url"], repo: repo) do
      {:ok, %{"url" => url}} when is_binary(url) and url != "" -> {:ok, url}
      {:ok, _other} -> {:error, {:gh_failed, ["pr", "view", head, "--json", "url"], 0, ""}}
      {:error, _reason} = error -> error
    end
  end

  @spec decode_json(String.t()) :: {:ok, json()} | {:error, error()}
  defp decode_json(output) do
    case Jason.decode(output) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, {:gh_failed, ["pr", "view"], 0, output}}
      {:error, _reason} -> {:error, {:gh_failed, ["pr", "view", "--json"], 0, output}}
    end
  end

  @spec run([String.t()], String.t() | nil) :: {:ok, String.t()} | {:error, error()}
  defp run(args, repo) do
    case runner().(args, cmd_opts(repo)) do
      :not_found -> {:error, :gh_not_found}
      {output, 0} -> {:ok, output}
      {output, status} when is_integer(status) -> classify_failure(args, status, output)
    end
  end

  @spec classify_failure([String.t()], integer(), String.t()) :: {:error, error()}
  defp classify_failure(args, status, output) do
    if unauthenticated?(output) do
      {:error, {:gh_unauthenticated, output}}
    else
      {:error, {:gh_failed, args, status, output}}
    end
  end

  @spec unauthenticated?(String.t()) :: boolean()
  defp unauthenticated?(output) do
    String.contains?(output, "gh auth login") or String.contains?(output, "GH_TOKEN")
  end

  @spec runner() :: ([String.t()], keyword() -> :not_found | {String.t(), integer()})
  defp runner do
    Application.get_env(:harness, :gh_cmd, &default_gh/2)
  end

  @spec default_gh([String.t()], keyword()) :: :not_found | {String.t(), integer()}
  defp default_gh(args, opts) do
    case System.find_executable("gh") do
      nil ->
        :not_found

      _path ->
        # argv-list spawn — no shell, no interpolation (same as Git.run/2).
        # sobelow_skip ["CI.System"]
        System.cmd("gh", args, opts)
    end
  end

  @spec cmd_opts(String.t() | nil) :: keyword()
  defp cmd_opts(nil), do: [stderr_to_stdout: true]
  defp cmd_opts(repo), do: [cd: repo, stderr_to_stdout: true]
end
