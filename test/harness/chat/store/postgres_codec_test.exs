defmodule Harness.Chat.Store.PostgresCodecTest do
  @moduledoc """
  Unit tests for the Postgres backend's error handling + JSON-decode codec —
  the changeset/rescue paths and the `decode_*` helpers that restore atom keys
  and atom role values after jsonb serialization — exercised through
  `save/3` / `load/2` / `list/1` with an in-process fake repo, so the backend
  is graded by the default (non-`:integration`) suite.

  The live-DB round-trip stays in `Harness.Chat.Store.PostgresTest`
  (`:integration`). This module exists so the rescue branches and decode edges
  are graded by the mergeable bar without a Postgres instance.

  Mirrors `Harness.ResultStore.PostgresCodecTest`.
  """

  use ExUnit.Case, async: true

  alias Harness.Chat.Store.Postgres, as: PostgresStore
  alias Harness.Chat.Store.Postgres.ChatSession

  # A naive_datetime_usec, as the `updated_at` column carries; load/list call
  # `DateTime.from_naive!(updated_at, "Etc/UTC")` on it.
  @stamp ~N[2026-06-04 12:00:00.000000]

  defmodule FakeRepo do
    @moduledoc false
    # In-process repo: get/2 and all/1 return rows configured in the process
    # dict; insert/2 is a no-op success (save/3 only inspects the ok/error tag).

    @spec insert(Ecto.Changeset.t(), keyword()) :: {:ok, struct()}
    def insert(changeset, _opts) do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    end

    @spec get(module(), String.t()) :: struct() | nil
    def get(_schema, _id), do: Process.get({__MODULE__, :row}, nil)

    @spec all(Ecto.Query.t()) :: [struct()]
    def all(_query), do: Process.get({__MODULE__, :rows}, [])

    @spec put_row(struct() | nil) :: :ok
    def put_row(row), do: Process.put({__MODULE__, :row}, row) && :ok

    @spec put_rows([struct()]) :: :ok
    def put_rows(rows), do: Process.put({__MODULE__, :rows}, rows) && :ok
  end

  defmodule ChangesetErrorRepo do
    @moduledoc false
    # insert/2 fails with an invalid changeset → exercises save/3's
    # `{:error, cs} -> {:error, {:changeset, cs.errors}}` branch.

    @spec insert(Ecto.Changeset.t(), keyword()) :: {:error, Ecto.Changeset.t()}
    def insert(_changeset, _opts) do
      {:error, ChatSession.changeset(%ChatSession{}, %{})}
    end
  end

  defmodule RaisingRepo do
    @moduledoc false
    # Every op raises a genuine DB *failure* (a connection loss) → exercises the
    # best-effort rescue, which the narrowed `@persistence_errors` swallows.

    @spec insert(Ecto.Changeset.t(), keyword()) :: no_return()
    def insert(_changeset, _opts), do: raise(DBConnection.ConnectionError, "simulated connection loss")

    @spec get(module(), String.t()) :: no_return()
    def get(_schema, _id), do: raise(DBConnection.ConnectionError, "simulated connection loss")

    @spec all(Ecto.Query.t()) :: no_return()
    def all(_query), do: raise(DBConnection.ConnectionError, "simulated connection loss")
  end

  describe "save/3" do
    test "a successful insert returns :ok" do
      assert :ok = PostgresStore.save("chat-ok", [%{role: :user, content: "hi"}], repo: FakeRepo)
    end

    test "an insert changeset error surfaces as {:error, {:changeset, errors}}" do
      messages = [%{role: :user, content: "hi"}]

      assert {:error, {:changeset, errors}} =
               PostgresStore.save("chat-cs", messages, repo: ChangesetErrorRepo)

      assert is_list(errors)
    end

    test "a DB failure is rescued into {:error, exception}" do
      assert {:error, %DBConnection.ConnectionError{}} =
               PostgresStore.save("chat-boom", [%{role: :user, content: "x"}], repo: RaisingRepo)
    end

    test "a programmer error (undefined repo fn) propagates rather than being masked" do
      assert_raise UndefinedFunctionError, fn ->
        PostgresStore.save("chat-bug", [%{role: :user, content: "x"}], repo: NoSuchRepoModule)
      end
    end
  end

  describe "load/2 error + decode paths" do
    test "a DB failure is rescued into {:error, :not_found}" do
      assert {:error, :not_found} = PostgresStore.load("chat-boom", repo: RaisingRepo)
    end

    test "an absent row is {:error, :not_found}" do
      # FakeRepo.get returns nil when no row is configured for this test process.
      assert {:error, :not_found} = PostgresStore.load("chat-absent", repo: FakeRepo)
    end

    test "a row with nil messages decodes to an empty list" do
      FakeRepo.put_row(%ChatSession{session_id: "chat-nil", messages: nil, updated_at: @stamp})

      assert {:ok, %{session_id: "chat-nil", messages: []}} =
               PostgresStore.load("chat-nil", repo: FakeRepo)
    end

    test "string keys + role values are restored to atoms; nested content round-trips" do
      row = %ChatSession{
        session_id: "chat-dec",
        messages: [
          %{"role" => "user", "content" => "hello"},
          %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "hi"}]}
        ],
        updated_at: @stamp
      }

      FakeRepo.put_row(row)

      assert {:ok, %{messages: [user, assistant]}} = PostgresStore.load("chat-dec", repo: FakeRepo)
      assert user == %{role: :user, content: "hello"}
      assert assistant == %{role: :assistant, content: [%{type: "text", text: "hi"}]}
    end

    test "an unknown key is kept as a binary (Sobelow StringToAtom guard)" do
      novel_key = "totally_unknown_key_#{System.unique_integer([:positive])}"

      row = %ChatSession{
        session_id: "chat-key",
        messages: [%{"role" => "user", "content" => "hi", novel_key => 1}],
        updated_at: @stamp
      }

      FakeRepo.put_row(row)

      assert {:ok, %{messages: [decoded]}} = PostgresStore.load("chat-key", repo: FakeRepo)
      # Recognized keys interned to atoms; the novel key stays a binary so a
      # malformed row can never exhaust the atom table.
      assert decoded[:role] == :user
      assert decoded[novel_key] == 1
      refute Map.has_key?(decoded, String.to_atom(novel_key))
    end
  end

  describe "list/1 error path" do
    test "a DB failure is rescued into []" do
      assert [] = PostgresStore.list(repo: RaisingRepo)
    end

    test "summarizes configured rows with decoded labels" do
      FakeRepo.put_rows([
        %ChatSession{
          session_id: "chat-l",
          messages: [%{"role" => "user", "content" => "alpha question"}],
          updated_at: @stamp
        }
      ])

      assert [%{session_id: "chat-l", label: "alpha question", message_count: 1}] =
               PostgresStore.list(repo: FakeRepo)
    end
  end
end
