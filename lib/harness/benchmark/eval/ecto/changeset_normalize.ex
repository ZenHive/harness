defmodule Harness.Benchmark.Eval.Ecto.ChangesetNormalize do
  @moduledoc "Benchmark reference: email changeset normalization."
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{email: String.t() | nil}

  @primary_key false
  embedded_schema do
    field :email, :string
  end

  @doc false
  @spec changeset(%__MODULE__{} | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(data \\ %__MODULE__{}, attrs) do
    attrs = normalize_attrs(attrs)

    data
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_format(:email, ~r/@/)
  end

  @spec normalize_attrs(map()) :: map()
  defp normalize_attrs(%{"email" => email}) when is_binary(email), do: %{"email" => normalize_email(email)}
  defp normalize_attrs(%{email: email}) when is_binary(email), do: %{email: normalize_email(email)}
  defp normalize_attrs(attrs), do: attrs

  @spec normalize_email(String.t()) :: String.t()
  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
end
