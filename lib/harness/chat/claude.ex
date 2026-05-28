defmodule Harness.Chat.Claude do
  @moduledoc """
  Chat backend that spawns `claude -p` per turn against the user's Claude
  subscription (Task 82).

  Three standing rules are load-bearing here:

    * **Subscription, not API.** `ANTHROPIC_API_KEY` is scrubbed from the Port
      env (set to `false`, matching `Harness.AgentAdapter`). The headless
      `claude` binary therefore falls back to its OAuth/Max subscription
      transport — no metered API code path exists in this module.
    * **Library-first.** We do not hand-roll an HTTP+SSE client against the
      metered Anthropic API; `claude -p` already speaks the subscription path.
    * **Real MCP.** The MCP endpoint at `localhost:4018/harness/mcp` (Task 79
      rework via `anubis_mcp`) is offered to `claude -p` via `--mcp-config`.
      Tools (the descripex driver surface — Task 75) flow through that one
      channel.

  ## Per-turn lifecycle

  Each `stream/3` call:

  1. Resolves a per-session cwd (default
     `Path.join([tmp_dir!, "harness-chat", session_id])`, overridable via
     `backend_opts[:cwd]`). Claude stores its own conversation file under
     this cwd, so `--continue` resolves unambiguously across turns.
  2. Writes a per-session `.harness-mcp-config.json` pointing at the harness
     MCP endpoint (URL overridable via `backend_opts[:mcp_url]`).
  3. Builds the headless argv and spawns `claude -p` over the same
     `/bin/sh -c 'exec "$0" "$@" </dev/null'` Port wrapper used by
     `Harness.AgentAdapter` — immediate stdin EOF so headless `claude`
     does not stall peeking stdin.
  4. Drives the Port under total + idle deadlines (mirrors
     `Harness.AgentAdapter.Driver`), feeding each chunk into
     `Harness.Chat.Claude.StreamParser` and fanning normalized events
     through the supplied callback.

  Claude runs its own multi-turn tool-call loop entirely inside the spawned
  process — when it calls a harness MCP tool, that hits the Bandit endpoint
  served by `Harness.Dashboard.MCPServer`. From `Harness.Chat.Session`'s
  view, each `stream/3` call is one "assistant returns final text" event;
  the returned `content` contains only `:text` blocks (tool_use is consumed
  inside `claude -p`), so Session never branches into its own tool-call
  loop. Tool calls still surface in the dashboard transcript pane via the
  `{:tool_use, _}` callback events.

  ## Backend opts

    * `:session_id` (required) — chat session id, injected by
      `Harness.Chat.Session` for cwd derivation.
    * `:cwd` — override the default per-session workspace.
    * `:mcp_url` — override `http://localhost:4018/harness/mcp`.
    * `:model` — passed to `--model` when present.
    * `:total_timeout` / `:idle_timeout` — per-turn ms budgets (defaults
      mirror `Harness.AgentAdapter.Driver`).
    * `:env` — extra env map for the Port (merged after the
      `ANTHROPIC_API_KEY: false` scrub).
  """

  @behaviour Harness.Chat.Backend

  alias Harness.Chat.Backend
  alias Harness.Chat.Claude.StreamParser

  @sh "/bin/sh"
  @stdin_eof_script ~S(exec "$0" "$@" </dev/null)
  @claude_executable "claude"
  @default_mcp_url "http://localhost:4018/harness/mcp"
  @default_total_timeout 1_800_000
  @default_idle_timeout 300_000
  @mcp_config_filename ".harness-mcp-config.json"

  @impl Backend
  @spec stream(Backend.request(), Backend.stream_callback(), keyword()) ::
          {:ok, map()} | {:error, Backend.error()}
  def stream(request, callback, opts) when is_function(callback, 1) do
    with {:ok, session_id} <- fetch_session_id(opts),
         {:ok, prompt} <- extract_user_text(request[:messages] || []),
         cwd = Keyword.get(opts, :cwd, default_cwd(session_id)),
         :ok <- ensure_cwd(cwd),
         mcp_url = Keyword.get(opts, :mcp_url, @default_mcp_url),
         {:ok, mcp_config_path} <- write_mcp_config(cwd, mcp_url),
         system = Map.get(request, :system),
         resume_argv = resume_argv(request[:messages] || []),
         argv = build_argv(prompt, mcp_config_path, resume_argv, opts[:model], system),
         env = build_env(Keyword.get(opts, :env, %{})),
         {:ok, port} <- spawn_port(argv, cwd, env) do
      drive(port, callback, opts)
    end
  end

  # Builds the headless argv claude consumes. The prompt is the LAST positional
  # argument so any embedded spaces / shell metacharacters ride through the
  # `sh -c "exec ..."` wrapper as a single binary, never word-split.
  @doc false
  @spec build_argv(String.t(), String.t(), [String.t()], String.t() | nil, String.t() | nil) ::
          [String.t()]
  def build_argv(prompt, mcp_config_path, resume_argv, model, system) do
    base = [
      "-p",
      "--output-format",
      "stream-json",
      "--verbose",
      "--permission-mode",
      "bypassPermissions",
      "--mcp-config",
      mcp_config_path
    ]

    base ++
      model_argv(model) ++
      system_argv(system) ++
      resume_argv ++
      [prompt]
  end

  @spec model_argv(String.t() | nil) :: [String.t()]
  defp model_argv(nil), do: []
  defp model_argv(model) when is_binary(model), do: ["--model", model]

  @spec system_argv(String.t() | nil) :: [String.t()]
  defp system_argv(nil), do: []
  defp system_argv(""), do: []
  defp system_argv(text) when is_binary(text), do: ["--append-system-prompt", text]
  defp system_argv(_), do: []

  # `--continue` resumes the most recent conversation in `cwd`. The very first
  # turn has only the just-added user message; any subsequent turn carries
  # prior assistant content too, so `length(messages) > 1` is the resume gate.
  @doc false
  @spec resume_argv([map()]) :: [String.t()]
  def resume_argv(messages) when is_list(messages) do
    if length(messages) > 1, do: ["--continue"], else: []
  end

  @doc false
  @spec default_cwd(String.t()) :: String.t()
  def default_cwd(session_id) when is_binary(session_id) do
    Path.join([System.tmp_dir!(), "harness-chat", session_id])
  end

  # `path` is built from a harness-controlled cwd (per-session tmp dir or a
  # caller-supplied override) plus a module-constant filename — not user input
  # arriving from HTTP. Sobelow's directory-traversal heuristic is a false
  # positive here.
  # sobelow_skip ["Traversal.FileModule"]
  @doc false
  @spec write_mcp_config(String.t(), String.t()) :: {:ok, String.t()} | {:error, Backend.error()}
  def write_mcp_config(cwd, mcp_url) when is_binary(cwd) and is_binary(mcp_url) do
    path = Path.join(cwd, @mcp_config_filename)
    body = Jason.encode!(%{mcpServers: %{harness: %{type: "http", url: mcp_url}}})

    case File.write(path, body) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, %{type: :mcp_config_write_failed, message: inspect(reason)}}
    end
  end

  @doc false
  @spec extract_user_text([map()]) :: {:ok, String.t()} | {:error, Backend.error()}
  def extract_user_text(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&user_message?/1)
    |> case do
      %{content: text} when is_binary(text) -> {:ok, text}
      %{"content" => text} when is_binary(text) -> {:ok, text}
      nil -> {:error, %{type: :no_user_message, message: "no user message in request"}}
      _ -> {:error, %{type: :unsupported_user_content, message: "user content must be a string"}}
    end
  end

  @spec user_message?(map()) :: boolean()
  defp user_message?(%{role: :user}), do: true
  defp user_message?(%{role: "user"}), do: true
  defp user_message?(%{"role" => "user"}), do: true
  defp user_message?(%{"role" => :user}), do: true
  defp user_message?(_), do: false

  @spec fetch_session_id(keyword()) :: {:ok, String.t()} | {:error, Backend.error()}
  defp fetch_session_id(opts) do
    case Keyword.fetch(opts, :session_id) do
      {:ok, id} when is_binary(id) and id != "" ->
        {:ok, id}

      _ ->
        {:error, %{type: :missing_session_id, message: "backend_opts[:session_id] is required"}}
    end
  end

  # `cwd` is a harness-derived per-session path or a caller-supplied override —
  # never user input from HTTP. Sobelow's traversal heuristic is a false
  # positive here.
  # sobelow_skip ["Traversal.FileModule"]
  @spec ensure_cwd(String.t()) :: :ok | {:error, Backend.error()}
  defp ensure_cwd(cwd) do
    case File.mkdir_p(cwd) do
      :ok -> :ok
      {:error, reason} -> {:error, %{type: :cwd_create_failed, message: inspect(reason)}}
    end
  end

  @doc false
  @spec build_env(map()) :: [{String.t(), String.t() | false}]
  def build_env(extra) when is_map(extra) do
    # Subscription/OAuth path: scrub the metered-API key. Caller-supplied env
    # is merged AFTER the scrub so an explicit re-introduction would be honored
    # (we do not silently overwrite a deliberate caller decision), but the
    # default is always-scrub.
    base = %{"ANTHROPIC_API_KEY" => false}
    merged = Map.merge(base, extra)
    Enum.to_list(merged)
  end

  @spec spawn_port([String.t()], String.t(), [{String.t(), String.t() | false}]) ::
          {:ok, port()} | {:error, Backend.error()}
  defp spawn_port(argv, cwd, env) do
    case System.find_executable(@claude_executable) do
      nil ->
        {:error,
         %{
           type: :claude_not_installed,
           message: "`claude` executable not found on PATH — install Claude Code"
         }}

      path ->
        port =
          Port.open({:spawn_executable, @sh}, [
            :binary,
            :exit_status,
            :hide,
            :stderr_to_stdout,
            {:args, ["-c", @stdin_eof_script, path | argv]},
            {:cd, cwd},
            {:env, port_env(env)}
          ])

        {:ok, port}
    end
  end

  @spec port_env([{String.t(), String.t() | false}]) :: [{charlist(), charlist() | false}]
  defp port_env(env) do
    Enum.map(env, fn
      {key, false} -> {String.to_charlist(key), false}
      {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  # Drives the Port under total + idle deadlines. Mirrors the
  # `Harness.AgentAdapter.Driver.loop/7` shape — the chat backend has no
  # subscriber hooks, but the deadline math is the same.
  @spec drive(port(), Backend.stream_callback(), keyword()) ::
          {:ok, map()} | {:error, Backend.error()}
  defp drive(port, callback, opts) do
    total = Keyword.get(opts, :total_timeout, @default_total_timeout)
    idle = Keyword.get(opts, :idle_timeout, @default_idle_timeout)
    started_ms = System.monotonic_time(:millisecond)
    loop(port, callback, started_ms + total, idle, idle_deadline(idle), StreamParser.new(), [], nil)
  end

  @spec loop(
          port(),
          Backend.stream_callback(),
          integer(),
          non_neg_integer(),
          integer(),
          StreamParser.t(),
          [map()],
          String.t() | nil
        ) :: {:ok, map()} | {:error, Backend.error()}
  defp loop(port, callback, total_deadline, idle, idle_deadline, parser, content_acc, stop_reason) do
    wait = min(remaining(total_deadline), remaining(idle_deadline))

    if wait == 0 do
      close_port(port)
      {:error, timeout_error(total_deadline)}
    else
      receive_one(port, callback, total_deadline, idle, parser, content_acc, stop_reason, wait)
    end
  end

  @spec receive_one(
          port(),
          Backend.stream_callback(),
          integer(),
          non_neg_integer(),
          StreamParser.t(),
          [map()],
          String.t() | nil,
          non_neg_integer()
        ) :: {:ok, map()} | {:error, Backend.error()}
  defp receive_one(port, callback, total_deadline, idle, parser, content_acc, stop_reason, wait) do
    receive do
      {^port, {:data, data}} ->
        {events, parser} = StreamParser.feed(parser, data)
        {content_acc, stop_reason} = handle_events(events, callback, content_acc, stop_reason)
        loop(port, callback, total_deadline, idle, idle_deadline(idle), parser, content_acc, stop_reason)

      {^port, {:exit_status, status}} ->
        {events, _parser} = StreamParser.finalize(parser)
        {content_acc, stop_reason} = handle_events(events, callback, content_acc, stop_reason)
        finalize_outcome(status, content_acc, stop_reason)
    after
      wait ->
        close_port(port)
        {:error, timeout_error(total_deadline)}
    end
  end

  @spec handle_events([StreamParser.event()], Backend.stream_callback(), [map()], String.t() | nil) ::
          {[map()], String.t() | nil}
  defp handle_events(events, callback, content_acc, stop_reason) do
    Enum.reduce(events, {content_acc, stop_reason}, fn event, acc -> handle_event(event, callback, acc) end)
  end

  @spec handle_event(StreamParser.event(), Backend.stream_callback(), {[map()], String.t() | nil}) ::
          {[map()], String.t() | nil}
  defp handle_event({:assistant_text, text}, callback, {acc, reason}) do
    safe_callback(callback, {:text_delta, text})
    {[%{"type" => "text", "text" => text} | acc], reason}
  end

  defp handle_event({:assistant_tool_use, tool_use}, callback, {acc, reason}) do
    # Surface the tool call to the dashboard/transcript via :tool_use callback
    # but DO NOT add it to `content_acc`. If we did, `Session.extract_tool_uses/1`
    # would loop on it — but Claude already handled the dispatch internally.
    safe_callback(callback, {:tool_use, tool_use})
    {acc, reason}
  end

  defp handle_event({:tool_result, _result}, _callback, acc) do
    # Claude's own tool-result echo — observational only.
    acc
  end

  defp handle_event({:result, result}, _callback, {acc, _reason}) do
    {acc, Map.get(result, "stop_reason") || Map.get(result, "subtype") || "end_turn"}
  end

  defp handle_event({:system_init, _}, _callback, acc), do: acc
  defp handle_event({:unknown, _}, _callback, acc), do: acc

  @spec finalize_outcome(integer(), [map()], String.t() | nil) ::
          {:ok, map()} | {:error, Backend.error()}
  defp finalize_outcome(0, content_acc, stop_reason) do
    {:ok, %{content: Enum.reverse(content_acc), stop_reason: stop_reason || "end_turn"}}
  end

  defp finalize_outcome(status, _content_acc, _stop_reason) do
    {:error, %{type: :claude_exit, message: "claude exited with status #{status}", status: status}}
  end

  @spec safe_callback(Backend.stream_callback(), Backend.event()) :: :ok
  defp safe_callback(callback, event) do
    callback.(event)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @spec close_port(port()) :: :ok
  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  @spec idle_deadline(non_neg_integer()) :: integer()
  defp idle_deadline(idle), do: System.monotonic_time(:millisecond) + idle

  @spec remaining(integer()) :: non_neg_integer()
  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  @spec timeout_error(integer()) :: Backend.error()
  defp timeout_error(total_deadline) do
    kind = if System.monotonic_time(:millisecond) >= total_deadline, do: :total, else: :idle
    %{type: :timeout, message: "claude turn timed out (#{kind} deadline)"}
  end
end
