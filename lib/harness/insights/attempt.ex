defmodule Harness.Insights.Attempt do
  @moduledoc "Mechanical ownership and recovery of interrupted observation attempts."
  alias Harness.Insights.Store

  @doc "Identifies the live process and VM incarnation owning a pass."
  @spec owner() :: map()
  def owner do
    %{"node" => to_string(node()), "pid" => self() |> :erlang.pid_to_list() |> to_string(), "boot" => boot()}
  end

  @doc "Reconciles abandoned passes after worker death or a VM restart."
  @spec reconcile() :: :ok | {:error, term()}
  def reconcile do
    reconcile_page(0)
  end

  @spec reconcile_page(non_neg_integer()) :: :ok | {:error, term()}
  defp reconcile_page(offset) do
    passes = Store.list("pass", offset, 100)

    Enum.each(passes, &reconcile_pass/1)
    if Enum.count_until(passes, 100) == 100, do: reconcile_page(offset + 100), else: :ok
  end

  @spec reconcile_pass(map()) :: term()
  defp reconcile_pass(pass) do
    if is_binary(pass["id"]) and pass["state"] == "observing" and abandoned?(pass) do
      Store.serialized(fn -> fail_if_abandoned(pass["id"]) end)
    end
  end

  @spec fail_if_abandoned(String.t()) :: term()
  defp fail_if_abandoned(id) do
    current = Store.get("pass/" <> id)
    if current["state"] == "observing" and abandoned?(current), do: fail(current, :interrupted)
  end

  @doc "Persists failure separately from the successful evidence checkpoint."
  @spec fail(map(), term()) :: :ok | {:error, term()}
  def fail(pass, reason) do
    Store.put_many([
      {"pass/" <> pass["id"], "pass",
       Map.merge(pass, %{"state" => "failed", "committed" => false, "error" => inspect(reason)})}
    ])
  end

  @spec abandoned?(map()) :: boolean()
  defp abandoned?(%{"owner" => %{"node" => owner_node, "pid" => pid, "boot" => started}} = pass) do
    if owner_node == to_string(node()) do
      started != boot() or not Process.alive?(:erlang.list_to_pid(String.to_charlist(pid)))
    else
      abandoned?(Map.delete(pass, "owner"))
    end
  end

  defp abandoned?(%{"at" => at}) do
    case DateTime.from_iso8601(at) do
      {:ok, date, _} -> DateTime.diff(DateTime.utc_now(), date) > 240
      _ -> true
    end
  end

  defp abandoned?(_), do: true

  @spec boot() :: String.t()
  defp boot do
    key = {__MODULE__, :boot}

    case :persistent_term.get(key, nil) do
      nil -> :global.trans({key, self()}, fn -> initialize_boot(key) end)
      id -> id
    end
  end

  @spec initialize_boot(tuple()) :: String.t()
  defp initialize_boot(key) do
    case :persistent_term.get(key, nil) do
      nil ->
        id = Ecto.UUID.generate()
        :persistent_term.put(key, id)
        id

      id ->
        id
    end
  end
end
