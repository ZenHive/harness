defmodule Harness.Maintenance.Recovery do
  @moduledoc "Reconciles worker death and preserves recoverable publication identities."
  alias Harness.Insights.Attempt
  alias Harness.Maintenance
  alias Harness.Maintenance.Store

  @doc "Marks an abandoned running pass failed after rechecking under the sweep lock."
  @spec reconcile(String.t()) :: :ok | {:error, term()}
  def reconcile(project) do
    progress = Store.get("progress/" <> project) || %{}

    if abandoned?(progress) do
      Store.serialized(fn -> fail_if_abandoned(project) end)
    else
      :ok
    end
  end

  @spec fail_if_abandoned(String.t()) :: :ok | {:error, term()}
  defp fail_if_abandoned(project) do
    current = Store.get("progress/" <> project) || %{}

    if abandoned?(current) do
      case Store.get("pass/" <> (current["id"] || "")) do
        %{"committed" => true} = pass ->
          persist(project, pass)

        %{} = pass ->
          persist(
            project,
            Map.merge(pass, %{"state" => "failed", "error" => "interrupted", "committed" => false})
          )

        _ ->
          persist(
            project,
            Map.merge(current, %{"state" => "failed", "error" => "interrupted", "committed" => false})
          )
      end
    else
      :ok
    end
  end

  @spec persist(String.t(), map()) :: :ok | {:error, term()}
  defp persist(project, pass) do
    documents =
      if is_binary(pass["id"]),
        do: [{"pass/" <> pass["id"], "pass", pass}],
        else: []

    with :ok <- Store.put_many(documents),
         do: Maintenance.progress(project, Map.delete(pass, "findings"))
  end

  @doc "Returns the incomplete discovery id so a new trigger recovers it before discovering more work."
  @spec pass_id(String.t()) :: String.t()
  def pass_id(project) do
    progress = Store.get("progress/" <> project) || %{}

    case Store.get("pass/" <> (progress["id"] || "")) do
      %{"committed" => false, "findings" => [_ | _], "id" => id} -> id
      _ -> Ecto.UUID.generate()
    end
  end

  @spec abandoned?(map()) :: boolean()
  defp abandoned?(%{"state" => "running", "owner" => owner, "expires_at" => expires}) do
    current = Attempt.owner()

    if owner["node"] == current["node"] do
      owner["boot"] != current["boot"] or not alive?(owner["pid"])
    else
      expires < DateTime.to_iso8601(DateTime.utc_now())
    end
  end

  defp abandoned?(_), do: false

  @spec alive?(term()) :: boolean()
  defp alive?(pid) when is_binary(pid) do
    pid |> String.to_charlist() |> :erlang.list_to_pid() |> Process.alive?()
  rescue
    ArgumentError -> false
  end

  defp alive?(_), do: false
end
