defmodule Harness.Run.Question do
  @moduledoc """
  The implementer question artifact — `.harness/question.json` — read mechanically.

  A headless implementer that hits genuinely ambiguous acceptance criteria writes
  this file and ends its invocation. Harness, at the agent-invocation boundary,
  reads the file as a fact: a well-formed, identity-fenced question parks the
  run in `:held` and emits a witness notification; anything else is
  ignored-and-logged and the run proceeds to commit/review. Harness never
  classifies, regex-matches, or branches on the question text.

      {
        "question": "which of these two readings of criterion 3 is intended?",
        "context": "optional extra prose",
        "run_id": "<HARNESS_RUN_ID>",
        "invocation": "<HARNESS_IMPLEMENTER_ATTEMPT>"
      }

  Identity is `run_id` + `invocation` (the attempt number injected into the
  Port env). A readable file whose echoed identity does not match this
  invocation is ignored, as is an id already recorded as consumed. Resume
  archives the answered question into `.harness/questions/` and records its
  id in `.harness/question-state.json` — consumption is that sidecar, not
  deleting `question.json` by convention. A later invocation may park on a
  new identity.

  The sidecar is the durable copy of pending/answered/consumed state for the
  live run process. A gen_statem crash while `:held` still settles `:failed`
  (`{:run_crashed, ...}`) like any other held crash; the retained worktree
  keeps the sidecar so the facts survive inspection and a same-process
  re-read cannot double-notify. A new run has a new worktree and a new
  `run_id`, so the sidecar cannot leak across runs.
  """

  alias Harness.Artifact
  alias Harness.Notification
  alias Harness.Notification.Event
  alias Harness.Worktree

  require Logger

  @artifact_path ".harness/question.json"
  @state_path ".harness/question-state.json"
  @archive_dir ".harness/questions"
  @run_id_env "HARNESS_RUN_ID"
  @invocation_env "HARNESS_IMPLEMENTER_ATTEMPT"

  @enforce_keys [:id, :run_id, :invocation, :question]
  defstruct [:id, :run_id, :invocation, :question, context: nil]

  @typedoc "A parsed question artifact."
  @type t :: %__MODULE__{
          id: String.t(),
          run_id: String.t(),
          invocation: String.t(),
          question: String.t(),
          context: String.t() | nil
        }

  @typedoc "Why an artifact could not be used as a pending question."
  @type error :: :missing | :empty | :consumed | :stale | {:malformed, term()}

  @typedoc "Run identity the current implementer invocation must echo into the artifact."
  @type identity :: %{run_id: String.t(), invocation: String.t()}

  @typedoc "Durable pending/consumed index stored next to the artifact."
  @type state :: %{
          pending: map() | nil,
          consumed: [String.t()]
        }

  @type data :: map()

  @doc "Relative path of the question artifact inside a run worktree."
  @spec artifact_path() :: String.t()
  def artifact_path, do: @artifact_path

  @doc "Relative path of the harness-owned pending/consumed sidecar."
  @spec state_path() :: String.t()
  def state_path, do: @state_path

  @doc "Port env var carrying the run id the implementer must echo into the artifact."
  @spec run_id_env() :: String.t()
  def run_id_env, do: @run_id_env

  @doc "Port env var carrying the implementer-attempt number the implementer must echo."
  @spec invocation_env() :: String.t()
  def invocation_env, do: @invocation_env

  @doc "Builds the identity map a later `read/2` compares against the artifact."
  @spec identity(String.t(), String.t() | integer()) :: identity()
  def identity(run_id, invocation) when is_binary(run_id) do
    %{run_id: run_id, invocation: to_string(invocation)}
  end

  @doc "Stable identity for one `{run, invocation}` pair."
  @spec id(String.t(), String.t()) :: String.t()
  def id(run_id, invocation) when is_binary(run_id) and is_binary(invocation) do
    run_id <> ":" <> invocation
  end

  @doc """
  Reads and parses the question artifact from `worktree_path`.

  `identity` is the run id and implementer-attempt this invocation handed the
  agent. A readable question whose echoed identity does not match is
  `{:error, :stale}`. An empty `question` string is `{:error, :empty}`.
  Missing or malformed files are the corresponding errors — never a crash.
  """
  @spec read(String.t(), identity()) :: {:ok, t()} | {:error, error()}
  def read(worktree_path, %{run_id: run_id, invocation: invocation})
      when is_binary(worktree_path) and is_binary(run_id) and is_binary(invocation) do
    with {:ok, contents} <- Artifact.read(worktree_path, @artifact_path),
         {:ok, question} <- parse(contents),
         :ok <- match_identity(question, run_id, invocation) do
      {:ok, question}
    end
  end

  @doc """
  Parses question-artifact JSON contents.

  ## Examples

      iex> {:ok, q} = Harness.Run.Question.parse(~s({"question": "which API?", "run_id": "run-1", "invocation": "0"}))
      iex> {q.question, q.id}
      {"which API?", "run-1:0"}
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, error()}
  def parse(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, decoded} when is_map(decoded) -> build(decoded)
      {:ok, other} -> {:error, {:malformed, {:not_a_map, other}}}
      {:error, reason} -> {:error, {:malformed, {:invalid_json, reason}}}
    end
  end

  @doc "Loads the harness-owned sidecar, or an empty state when it is absent/unusable."
  @spec load_state(String.t()) :: state()
  def load_state(worktree_path) when is_binary(worktree_path) do
    case Artifact.read(worktree_path, @state_path) do
      {:ok, contents} -> parse_state(contents)
      {:error, _reason} -> empty_state()
    end
  end

  @doc """
  Inspects the worktree at the implementer-invocation boundary.

  Returns `{:park, data, question, notify?}` when a fenced, unconsumed question
  is present. `notify?` is false when the sidecar already recorded this id as
  notified, so a same-process re-read cannot duplicate the witness. Any other
  outcome is `:ignore` (missing, empty, malformed, stale, or consumed) and is
  logged when the file existed but was not usable.
  """
  @spec take(data()) :: {:park, data(), t(), boolean()} | :ignore
  def take(%{worktree: %Worktree{path: path}, run_id: run_id} = data) when is_binary(path) do
    identity = identity(run_id, implementer_attempt(data))
    sidecar = load_state(path)
    consumed = merge_consumed(data, sidecar)

    case read(path, identity) do
      {:ok, question} ->
        decide_take(data, sidecar, consumed, question)

      {:error, :missing} ->
        :ignore

      {:error, reason} ->
        log_ignored(run_id, reason)
        :ignore
    end
  end

  def take(_data), do: :ignore

  @doc "Persists pending question + notified flag, returning updated run data."
  @spec park(data(), t()) :: data()
  def park(%{worktree: %Worktree{path: path}} = data, %__MODULE__{} = question) do
    sidecar = load_state(path)
    consumed = merge_consumed(data, sidecar)
    pending = pending_map(question, notified: true, answer: sidecar_answer(sidecar, question.id))
    write_state(path, %{pending: pending, consumed: consumed})

    %{data | pending_question: question, consumed_question_ids: consumed, hold_reason: :question}
  end

  @doc "Emits the `:question` witness event carrying the question string verbatim."
  @spec notify_parked(data(), t()) :: :ok
  def notify_parked(data, %__MODULE__{} = question) do
    Notification.notify(%Event{
      type: :question,
      task_id: to_string(data.item.id),
      run_id: data.run_id,
      project: data.project.name,
      branch: "harness/" <> data.run_id,
      land_attempt: data.land_attempt,
      outcome: %{
        id: question.id,
        question: question.question,
        context: question.context,
        invocation: question.invocation
      }
    })
  end

  @doc "Writes the steer answer onto the sidecar pending record when one exists."
  @spec record_answer(data(), String.t()) :: data()
  def record_answer(%{worktree: %Worktree{path: path}, pending_question: %__MODULE__{} = question} = data, text)
      when is_binary(path) and is_binary(text) do
    sidecar = load_state(path)
    consumed = merge_consumed(data, sidecar)
    pending = pending_map(question, notified: true, answer: text)
    write_state(path, %{pending: pending, consumed: consumed})
    data
  end

  def record_answer(data, _text), do: data

  @doc """
  Archives the pending question as consumed after a successful question-resume.

  The original `question.json` is left in place; the sidecar's `consumed` list
  is what prevents that identity from parking again.
  """
  @spec consume_if_answered(data()) :: data()
  def consume_if_answered(
        %{worktree: %Worktree{path: path}, pending_question: %__MODULE__{} = question, operator_feedback: answer} = data
      )
      when is_binary(path) and is_binary(answer) and answer != "" do
    sidecar = load_state(path)
    consumed = Enum.uniq(merge_consumed(data, sidecar) ++ [question.id])
    archive_answered(path, question, answer)
    write_state(path, %{pending: nil, consumed: consumed})
    %{data | pending_question: nil, consumed_question_ids: consumed}
  end

  def consume_if_answered(data), do: data

  @doc "Prompt fragment injecting the parked question and the steer answer."
  @spec answer_prompt(t(), String.t()) :: String.t()
  def answer_prompt(%__MODULE__{} = question, answer) when is_binary(answer) do
    """
    You previously parked this run with a question:

    #{question.question}
    #{context_block(question.context)}
    An orchestrator answered via dispatch-steer:

    #{answer}

    Continue the task in light of that answer. Do not re-ask the same question.
    """
  end

  @spec build(map()) :: {:ok, t()} | {:error, error()}
  defp build(decoded) do
    with {:ok, question_text} <- required_question(decoded),
         {:ok, run_id} <- required_string(decoded, "run_id"),
         {:ok, invocation} <- required_string(decoded, "invocation") do
      {:ok,
       %__MODULE__{
         id: id(run_id, invocation),
         run_id: run_id,
         invocation: invocation,
         question: question_text,
         context: optional_string(decoded, "context")
       }}
    end
  end

  @spec required_question(map()) :: {:ok, String.t()} | {:error, error()}
  defp required_question(decoded) do
    case Map.get(decoded, "question") do
      text when is_binary(text) ->
        if String.trim(text) == "", do: {:error, :empty}, else: {:ok, text}

      _other ->
        {:error, {:malformed, :missing_question}}
    end
  end

  @spec required_string(map(), String.t()) :: {:ok, String.t()} | {:error, error()}
  defp required_string(decoded, key) do
    case Map.get(decoded, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_integer(value) -> {:ok, Integer.to_string(value)}
      _other -> {:error, {:malformed, {:missing_field, key}}}
    end
  end

  @spec optional_string(map(), String.t()) :: String.t() | nil
  defp optional_string(decoded, key) do
    case Map.get(decoded, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  @spec match_identity(t(), String.t(), String.t()) :: :ok | {:error, :stale}
  defp match_identity(%__MODULE__{run_id: run_id, invocation: invocation}, run_id, invocation), do: :ok
  defp match_identity(_question, _run_id, _invocation), do: {:error, :stale}

  @spec decide_take(data(), state(), [String.t()], t()) :: {:park, data(), t(), boolean()} | :ignore
  defp decide_take(data, sidecar, consumed, question) do
    if question.id in consumed do
      log_ignored(data.run_id, :consumed)
      :ignore
    else
      notify? = not already_notified?(sidecar, question.id)
      {:park, %{data | consumed_question_ids: consumed}, question, notify?}
    end
  end

  @spec already_notified?(state(), String.t()) :: boolean()
  defp already_notified?(%{pending: %{"id" => id, "notified" => true}}, id), do: true
  defp already_notified?(%{pending: %{id: id, notified: true}}, id), do: true
  defp already_notified?(_state, _id), do: false

  @spec sidecar_answer(state(), String.t()) :: String.t() | nil
  defp sidecar_answer(%{pending: %{"id" => id, "answer" => answer}}, id) when is_binary(answer), do: answer
  defp sidecar_answer(%{pending: %{id: id, answer: answer}}, id) when is_binary(answer), do: answer
  defp sidecar_answer(_state, _id), do: nil

  @spec pending_map(t(), keyword()) :: map()
  defp pending_map(%__MODULE__{} = question, opts) do
    %{
      "id" => question.id,
      "run_id" => question.run_id,
      "invocation" => question.invocation,
      "question" => question.question,
      "context" => question.context,
      "notified" => Keyword.get(opts, :notified, true),
      "answer" => Keyword.get(opts, :answer)
    }
  end

  @spec parse_state(binary()) :: state()
  defp parse_state(contents) do
    case Jason.decode(contents) do
      {:ok, decoded} when is_map(decoded) ->
        %{
          pending: state_pending(decoded),
          consumed: state_consumed(decoded)
        }

      _other ->
        empty_state()
    end
  end

  @spec state_pending(map()) :: map() | nil
  defp state_pending(decoded) do
    case Map.get(decoded, "pending") do
      pending when is_map(pending) -> pending
      _other -> nil
    end
  end

  @spec state_consumed(map()) :: [String.t()]
  defp state_consumed(decoded) do
    case Map.get(decoded, "consumed") do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _other -> []
    end
  end

  @spec empty_state() :: state()
  defp empty_state, do: %{pending: nil, consumed: []}

  @spec merge_consumed(data(), state()) :: [String.t()]
  defp merge_consumed(data, sidecar) do
    memory = List.wrap(Map.get(data, :consumed_question_ids, []))
    Enum.uniq(memory ++ sidecar.consumed)
  end

  @spec implementer_attempt(data()) :: String.t()
  defp implementer_attempt(%{implementer_attempt: attempt}) when is_integer(attempt) do
    to_string(attempt)
  end

  defp implementer_attempt(%{implementer_attempt: attempt}) when is_binary(attempt), do: attempt
  defp implementer_attempt(_data), do: "0"

  @spec write_state(String.t(), state()) :: :ok
  # sobelow_skip ["Traversal.FileModule"]
  # root is the harness-generated run worktree, never user input.
  defp write_state(worktree_path, state) do
    path = Path.join(worktree_path, @state_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(state))
    :ok
  rescue
    error in [File.Error, Jason.EncodeError] ->
      Logger.warning("harness run: failed to persist question-state.json: #{inspect(error)}")
      :ok
  end

  @spec archive_answered(String.t(), t(), String.t()) :: :ok
  # sobelow_skip ["Traversal.FileModule"]
  # archive name is derived from harness-issued run_id + invocation, never agent text.
  defp archive_answered(worktree_path, question, answer) do
    dir = Path.join(worktree_path, @archive_dir)
    File.mkdir_p!(dir)
    name = question.run_id <> "-" <> question.invocation <> ".answered.json"

    payload = %{
      "id" => question.id,
      "run_id" => question.run_id,
      "invocation" => question.invocation,
      "question" => question.question,
      "context" => question.context,
      "answer" => answer
    }

    File.write!(Path.join(dir, name), Jason.encode!(payload))
    :ok
  rescue
    error in [File.Error, Jason.EncodeError] ->
      Logger.warning("harness run: failed to archive answered question: #{inspect(error)}")
      :ok
  end

  @spec context_block(String.t() | nil) :: String.t()
  defp context_block(nil), do: ""
  defp context_block(""), do: ""
  defp context_block(context), do: "\nContext:\n\n#{context}\n"

  @spec log_ignored(String.t(), error()) :: :ok
  defp log_ignored(run_id, reason) do
    Logger.warning("harness run: ignoring question.json for #{run_id}: #{inspect(reason)}")
    :ok
  end
end
