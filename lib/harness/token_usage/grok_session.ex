defmodule Harness.TokenUsage.GrokSession do
  @moduledoc """
  Recovers grok token usage from its on-disk session log.

  Grok's headless `--output-format streaming-json` stdout — the stream harness
  captures over the Port — carries only `thought`/`text`/`end` events and **no
  token usage** (the terminal `end` event is just `stopReason` + `sessionId` +
  `requestId`). Grok *does* record usage, but to a session log under `$HOME`:

      ~/.grok/sessions/<percent-encoded cwd>/<session-id>/updates.jsonl

  Because that path is under `$HOME` (not the worktree), it survives the worktree
  teardown harness performs after a run. Each `session/update` event carries a
  **cumulative** `_meta.totalTokens`; the maximum across the file is the
  session's total burn. There is no input/output split on the wire, so only
  `:total` is populated.

  This is a deliberate **side-channel read** — the single exception to harness's
  "capture Port stdout only" rule — justified because grok's stdout structurally
  omits the data. Locating the file by the globally-unique `sessionId` (globbed
  across cwd-roots) sidesteps reconstructing grok's cwd percent-encoding.

  Tolerant by construction: a missing session id, an absent dir/file, an
  unreadable log, or a log with no `totalTokens` all yield `TokenUsage.empty/0`,
  never a raise.

  The sessions root is `~/.grok/sessions`, overridable via the
  `:grok_sessions_root` app-env key (test-only — points the glob at a fixture
  tree).
  """

  alias Harness.TokenUsage

  @total_tokens_re ~r/"totalTokens":\s*(\d+)/

  @doc """
  Recovers a grok run's cumulative token usage from its session log.

  `transcript` is grok's captured stdout — its terminal `end` event supplies the
  `sessionId` used to locate the log. Returns a `%TokenUsage{}` carrying only
  `:total` (grok reports no input/output split), or `TokenUsage.empty/0` when the
  log can't be found or carries no usage.
  """
  # sobelow_skip ["Traversal.FileModule"] — `id` is constrained to a uuid-shaped
  # token by `safe_id/1` (no `/` or `.`), so it can't escape `sessions_root`.
  @spec usage(term()) :: TokenUsage.t()
  def usage(transcript) when is_binary(transcript) do
    with id when is_binary(id) <- session_id(transcript),
         path when is_binary(path) <- locate_log(id),
         {:ok, contents} <- File.read(path) do
      contents |> max_total_tokens() |> to_usage()
    else
      _ -> TokenUsage.empty()
    end
  end

  def usage(_transcript), do: TokenUsage.empty()

  @spec session_id(binary()) :: binary() | nil
  defp session_id(transcript) do
    transcript
    |> String.split("\n")
    |> Enum.find_value(&end_event_session_id/1)
  end

  @spec end_event_session_id(binary()) :: binary() | nil
  defp end_event_session_id(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"type" => "end", "sessionId" => id}} when is_binary(id) -> safe_id(id)
      _ -> nil
    end
  end

  # The session id becomes a path segment, so constrain it to the uuid charset
  # (grok session ids are uuids) — rejects any `/` or `.` traversal payload.
  @spec safe_id(binary()) :: binary() | nil
  defp safe_id(id) do
    if Regex.match?(~r/\A[A-Za-z0-9-]+\z/, id), do: id
  end

  @spec locate_log(binary()) :: binary() | nil
  defp locate_log(session_id) do
    [sessions_root(), "*", session_id, "updates.jsonl"]
    |> Path.join()
    |> Path.wildcard()
    |> List.first()
  end

  @spec max_total_tokens(binary()) :: non_neg_integer() | nil
  defp max_total_tokens(contents) do
    @total_tokens_re
    |> Regex.scan(contents, capture: :all_but_first)
    |> Enum.reduce(nil, fn [n], acc -> max(String.to_integer(n), acc || 0) end)
  end

  @spec to_usage(non_neg_integer() | nil) :: TokenUsage.t()
  defp to_usage(nil), do: TokenUsage.empty()
  defp to_usage(total), do: %TokenUsage{total: total}

  @spec sessions_root() :: binary()
  defp sessions_root do
    Application.get_env(:harness, :grok_sessions_root) || Path.expand("~/.grok/sessions")
  end
end
