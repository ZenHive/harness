defmodule Harness.Projects.DispatchQA do
  @moduledoc """
  Operator-invoked rollout of focused dispatch checks and post-merge audit QA.

  Default is dry-run. `--apply` installs focused dispatch and full QA commands
  together. QA outcomes never gate this separation. Failed upserts restore
  captured prior settings.
  """

  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ProjectRegistry.Schema.Project, as: ProjectSchema
  alias Harness.Projects.DispatchQA.Catalog
  alias Harness.Projects.DispatchQA.Hooks
  alias Harness.Repo
  alias Harness.SafeTerm

  @type status ::
          :unchanged
          | :qa_installed
          | :dispatch_switched
          | :retained
          | :unavailable
          | :failed

  @type project_result :: %{
          name: String.t(),
          status: status(),
          prior: map() | nil,
          desired: map() | nil,
          readback: map() | nil,
          reason: String.t() | nil,
          write_set: [String.t()]
        }

  @doc "Fleet catalog used by inventory, plan, and activate."
  @spec catalog() :: [Catalog.entry()]
  def catalog, do: Catalog.all()

  @doc "Captures live registry settings, repo surfaces, and hook configs."
  @spec inventory(keyword()) :: map()
  def inventory(opts \\ []) do
    entries = catalog_entries(opts)
    lookup = Keyword.get(opts, :lookup, &persisted_lookup/1)

    %{
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      projects: Enum.map(entries, &inventory_project(&1, lookup)),
      hooks: Hooks.inventory(opts)
    }
  end

  @doc "Computes the per-project plan without mutating settings."
  @spec plan(keyword()) :: [project_result()]
  def plan(opts \\ []) do
    lookup = Keyword.get(opts, :lookup, &persisted_lookup/1)

    Enum.map(catalog_entries(opts), &plan_project(&1, lookup))
  end

  @doc """
  Applies the plan when `apply: true`. Always writes a prior-settings capture.

  Without `apply: true` this is inventory + plan + capture only.
  """
  @spec activate(keyword()) :: {:ok, map()} | {:error, term()}
  def activate(opts \\ []) do
    capture_dir = Keyword.get(opts, :capture_dir) || System.tmp_dir!()
    apply? = Keyword.get(opts, :apply, false)
    planned = plan(opts)

    with {:ok, capture_path} <- write_capture(capture_dir, planned, inventory(opts)),
         {:ok, result} <- persist_result(capture_path, planned, apply?, opts) do
      activation_outcome(result)
    end
  end

  @doc "Reads current check/qa commands for catalog names."
  @spec readback(keyword()) :: [map()]
  def readback(opts \\ []) do
    lookup = Keyword.get(opts, :lookup, &persisted_lookup/1)

    Enum.map(catalog_entries(opts), fn entry ->
      case lookup.(entry.name) do
        {:ok, project} ->
          %{
            name: entry.name,
            check_command: project.check_command,
            qa_command: project.qa_command,
            landing_policy: project.landing_policy,
            concurrency_cap: project.concurrency_cap,
            reviewer: project.reviewer,
            target_branch: project.target_branch,
            available?: true
          }

        {:error, _reason} ->
          %{name: entry.name, available?: false, reason: "unregistered"}
      end
    end)
  end

  @spec catalog_entries(keyword()) :: [Catalog.entry()]
  defp catalog_entries(opts) do
    names = Keyword.get(opts, :names)

    if is_list(names) do
      Enum.map(names, fn name ->
        Catalog.entry(name) || %{name: name, dispatch: nil, qa: nil, write_set: [], notes: "Unknown catalog project"}
      end)
    else
      Catalog.all()
    end
  end

  @spec inventory_project(Catalog.entry(), (String.t() -> {:ok, Project.t()} | {:error, term()})) :: map()
  defp inventory_project(entry, lookup) do
    case lookup.(entry.name) do
      {:ok, project} ->
        %{
          name: entry.name,
          available?: true,
          persisted: settings_snapshot(project),
          desired: %{check_command: entry.dispatch, qa_command: entry.qa},
          repo: repo_surface(project),
          hooks: Hooks.inventory(project_root: Project.repo_path(project), include_global: false),
          write_set: entry.write_set,
          notes: entry.notes
        }

      {:error, _reason} ->
        %{name: entry.name, available?: false, reason: "unregistered", write_set: entry.write_set, notes: entry.notes}
    end
  end

  @spec plan_project(
          Catalog.entry(),
          (String.t() -> {:ok, Project.t()} | {:error, term()})
        ) :: project_result()
  defp plan_project(entry, lookup) do
    case if(is_nil(entry.qa), do: {:error, :unknown_catalog_project}, else: lookup.(entry.name)) do
      {:ok, project} -> plan_registered(entry, project)
      {:error, _reason} -> unavailable(entry, "unregistered")
    end
  end

  @spec plan_registered(Catalog.entry(), Project.t()) ::
          project_result()
  defp plan_registered(entry, project) do
    prior = settings_snapshot(project)
    desired = %{check_command: entry.dispatch, qa_command: entry.qa}

    {status, reason} = plan_status(project, entry)

    %{
      name: entry.name,
      status: status,
      prior: prior,
      desired: desired,
      readback: prior,
      reason: reason,
      write_set: entry.write_set
    }
  end

  @spec plan_status(Project.t(), Catalog.entry()) :: {status(), String.t() | nil}
  defp plan_status(project, entry) do
    cond do
      project.qa_command == entry.qa and project.check_command == entry.dispatch ->
        {:unchanged, nil}

      project.qa_command != entry.qa ->
        {:qa_installed, "install full QA and focused dispatch commands together"}

      project.check_command != entry.dispatch ->
        {:dispatch_switched, nil}

      true ->
        {:unchanged, nil}
    end
  end

  @spec apply_project(project_result(), keyword()) :: project_result()
  defp apply_project(%{status: :unavailable} = result, _opts), do: result

  defp apply_project(result, opts) do
    lookup = Keyword.get(opts, :lookup, &persisted_lookup/1)
    upsert = Keyword.get(opts, :upsert, &ProjectRegistry.upsert/1)

    with {:ok, prior} <- lookup.(result.name),
         true <- settings_snapshot(prior) == result.prior || {:error, :settings_changed} do
      persist_plan(prior, lookup, upsert)
    else
      {:error, reason} -> %{result | status: :failed, reason: inspect(reason), readback: nil}
    end
  end

  @spec persist_plan(Project.t(), function(), function()) :: project_result()
  defp persist_plan(prior, lookup, upsert) do
    fresh = plan_registered(Catalog.entry(prior.name), prior)
    updated = apply_desired(fresh.status, prior, fresh.desired)

    case write_if_changed(prior, updated, upsert) do
      :ok -> confirm_or_rollback(fresh, prior, updated, upsert, lookup)
      {:error, reason} -> rollback(fresh, prior, upsert, lookup, reason)
    end
  end

  @spec apply_desired(status(), Project.t(), map()) :: Project.t()
  defp apply_desired(:qa_installed, prior, desired),
    do: %{prior | qa_command: desired.qa_command, check_command: desired.check_command}

  defp apply_desired(:dispatch_switched, prior, desired), do: %{prior | check_command: desired.check_command}
  defp apply_desired(_status, prior, _desired), do: prior

  @spec write_if_changed(Project.t(), Project.t(), function()) :: :ok | {:error, term()}
  defp write_if_changed(prior, prior, _upsert), do: :ok
  defp write_if_changed(_prior, updated, upsert), do: upsert.(updated)

  @spec confirm_or_rollback(project_result(), Project.t(), Project.t(), function(), function()) :: project_result()
  defp confirm_or_rollback(fresh, prior, updated, upsert, lookup) do
    case verify_readback(updated, lookup) do
      {:ok, actual} -> %{fresh | readback: settings_snapshot(actual)}
      {:error, reason} -> rollback(fresh, prior, upsert, lookup, reason)
    end
  end

  @spec verify_readback(Project.t(), function()) :: {:ok, Project.t()} | {:error, term()}
  defp verify_readback(expected, lookup) do
    with {:ok, actual} <- lookup.(expected.name),
         true <- actual == expected || {:error, :readback_mismatch} do
      {:ok, actual}
    end
  end

  @spec rollback(project_result(), Project.t(), function(), function(), term()) :: project_result()
  defp rollback(result, prior, upsert, lookup, reason) do
    restoration = with :ok <- upsert.(prior), do: verify_readback(prior, lookup)

    case restoration do
      {:ok, actual} -> %{result | status: :failed, reason: inspect(reason), readback: settings_snapshot(actual)}
      error -> %{result | status: :failed, reason: inspect({reason, {:restoration_failed, error}}), readback: nil}
    end
  end

  @doc "Reads both runtime and durable settings; persistence failures never masquerade as success."
  @spec persisted_lookup(String.t()) :: {:ok, Project.t()} | {:error, term()}
  def persisted_lookup(name) do
    with {:ok, live} <- ProjectRegistry.lookup(name),
         true <- Application.get_env(:harness, :repo_enabled, true) || {:error, :persistence_disabled},
         %ProjectSchema{payload: payload, warm_paths: warm_paths} <- Repo.get(ProjectSchema, name),
         {:ok, %{__struct__: Project, name: ^name} = stored} <- SafeTerm.decode(payload),
         persisted = struct(Project, Map.put(Map.from_struct(stored), :warm_paths, warm_paths || [])),
         true <- registration_fields(live) == registration_fields(persisted) || {:error, :persistence_mismatch} do
      {:ok, persisted}
    else
      nil -> {:error, :not_persisted}
      {:error, _} = error -> error
      _ -> {:error, :invalid_persisted_project}
    end
  rescue
    error in [RuntimeError, DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      {:error, {:persistence_unavailable, Exception.message(error)}}
  end

  @spec registration_fields(Project.t()) :: map()
  defp registration_fields(project), do: Map.drop(Map.from_struct(project), [:landing_policy, :target_branch, :reviewer])

  @spec settings_snapshot(Project.t()) :: map()
  defp settings_snapshot(project) do
    %{
      check_command: project.check_command,
      qa_command: project.qa_command,
      landing_policy: project.landing_policy,
      concurrency_cap: project.concurrency_cap,
      reviewer: project.reviewer,
      target_branch: project.target_branch
    }
  end

  @spec repo_surface(Project.t()) :: map()
  defp repo_surface(project) do
    path = Project.repo_path(project)

    case Harness.Git.run(["ls-files", "-z"], path) do
      {:ok, files} ->
        selected =
          files
          |> String.split(<<0>>, trim: true)
          |> Enum.filter(fn file ->
            Path.basename(file) in [
              "mix.exs",
              "mix_helpers.exs",
              "package.json",
              "Cargo.toml",
              "CLAUDE.md",
              "AGENTS.md",
              "Makefile",
              ".credo.exs",
              ".reach.exs"
            ]
          end)

        %{path: path, available?: true, files: Enum.map(selected, &Hooks.read_file(Path.join(path, &1)))}

      {:error, reason} ->
        %{path: path, available?: false, reason: inspect(reason)}
    end
  end

  @spec unavailable(Catalog.entry(), String.t()) :: project_result()
  defp unavailable(entry, reason) do
    %{
      name: entry.name,
      status: :unavailable,
      prior: nil,
      desired: %{check_command: entry.dispatch, qa_command: entry.qa},
      readback: nil,
      reason: reason,
      write_set: entry.write_set
    }
  end

  @spec persist_result(String.t(), [project_result()], boolean(), keyword()) :: {:ok, map()} | {:error, term()}
  defp persist_result(capture_path, planned, apply?, opts) do
    results = if apply?, do: Enum.map(planned, &apply_project(&1, opts)), else: planned
    result = %{capture_path: capture_path, applied?: apply?, projects: results}
    encoded = Jason.encode!(json_safe(result), pretty: true) <> "\n"

    # sobelow_skip ["Traversal.FileModule"] — capture_path is written under capture_dir (tmp or caller).
    case File.write(capture_path <> ".result.json", encoded, [:exclusive]) do
      :ok -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec activation_outcome(map()) :: {:ok, map()} | {:error, map()}
  defp activation_outcome(%{applied?: true, projects: results} = result) do
    if Enum.any?(results, &(&1.status in [:failed, :unavailable])), do: {:error, result}, else: {:ok, result}
  end

  defp activation_outcome(result), do: {:ok, result}

  @spec write_capture(String.t(), [project_result()], map()) :: {:ok, String.t()} | {:error, term()}
  defp write_capture(dir, planned, inventory) do
    # sobelow_skip ["Traversal.FileModule"] — dir is System.tmp_dir! or an explicit capture_dir.
    File.mkdir_p!(dir)
    path = Path.join(dir, "dispatch-qa-capture-#{Ecto.UUID.generate()}.json")

    payload = %{
      captured_at: inventory.captured_at,
      projects: Enum.map(planned, &json_project/1),
      inventory: json_safe(inventory)
    }

    # sobelow_skip ["Traversal.FileModule"] — path is capture_dir plus a generated UUID filename.
    case File.write(path, Jason.encode!(payload, pretty: true) <> "\n", [:exclusive]) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec json_project(project_result()) :: map()
  defp json_project(result) do
    result
    |> Map.update!(:status, &Atom.to_string/1)
    |> Map.update!(:prior, &json_safe/1)
    |> Map.update!(:desired, &json_safe/1)
    |> Map.update!(:readback, &json_safe/1)
  end

  @spec json_safe(term()) :: term()
  defp json_safe(value) when value in [nil, true, false], do: value
  defp json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe({:ok, value}), do: %{"ok" => json_safe(value)}
  defp json_safe({:error, reason}), do: %{"error" => json_safe(reason)}
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {json_key(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(other), do: other

  @spec json_key(term()) :: String.t()
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: inspect(key)
end
