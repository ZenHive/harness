defmodule Harness.Chat.Supervisor do
  @moduledoc """
  DynamicSupervisor for chat sessions — one crash-isolated GenServer per session id.
  """

  use DynamicSupervisor

  alias Harness.Chat.Session

  @registry Harness.Chat.Registry

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(init_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [init_arg]}, type: :supervisor}
  end

  @doc "Starts the chat session DynamicSupervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @impl DynamicSupervisor
  @spec init(keyword()) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a supervised chat session registered under `session_id`.

  Returns `{:ok, session_id, pid}` or `{:error, reason}`. Sessions are
  `:temporary` — a crash drops in-flight state without affecting siblings.
  """
  @spec start_session(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_session(opts \\ []) do
    session_id = Keyword.get(opts, :id, generate_session_id())

    child = %{
      id: {Session, session_id},
      start: {Session, :start_link, [session_id, opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, child) do
      {:ok, pid} -> {:ok, session_id, pid}
      {:error, {:already_started, pid}} -> {:ok, session_id, pid}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the ids of every currently-live chat session, via the Registry.

  Live sessions only — persisted-but-not-running sessions live in
  `Harness.Chat.Store`. `Harness.Dashboard.ChatLive`'s index merges the two.
  """
  @spec list_sessions() :: [String.t()]
  def list_sessions do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc "Looks up a session pid by `session_id` via the Registry."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @spec generate_session_id() :: String.t()
  defp generate_session_id do
    "chat-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
