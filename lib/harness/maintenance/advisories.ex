defmodule Harness.Maintenance.Advisories do
  @moduledoc "Read-only private advisory evidence; never logged or stored in public documents."

  alias Harness.Maintenance.Command

  @doc "Fetches accessible repository advisories using the operator's existing gh authentication."
  @spec read(String.t()) :: map()
  def read(root) do
    with executable when is_binary(executable) <- System.find_executable("gh"),
         {name, 0} <-
           Command.run(executable, ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
             cd: root,
             timeout: 15_000,
             stderr_to_stdout: true
           ),
         {output, 0} <-
           Command.run(executable, ["api", "repos/#{String.trim(name)}/security-advisories?per_page=100"],
             cd: root,
             timeout: 15_000,
             stderr_to_stdout: true
           ),
         {:ok, advisories} when is_list(advisories) <- Jason.decode(output) do
      %{
        "state" => "available",
        "private_evidence" => advisories,
        "possibly_truncated" => Enum.count_until(advisories, 100) == 100
      }
    else
      _ ->
        %{
          "state" => "unavailable",
          "reason" => "Repository advisories unavailable; verify gh authentication and repository access."
        }
    end
  end
end
