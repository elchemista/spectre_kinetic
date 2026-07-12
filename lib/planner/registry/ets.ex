defmodule SpectreKinetic.Planner.Registry.ETS do
  @moduledoc """
  Default ETS-backed registry backend for the Elixir planner runtime.

  The process that calls `new/1` owns the registry. Protected ETS tables allow
  other processes to plan against the handle, but only the owner may load,
  mutate, or close it. Use the supervised adapter when mutations need to be
  shared across callers.
  """

  @behaviour SpectreKinetic.Planner.Registry

  alias SpectreKinetic.Artifact
  alias SpectreKinetic.Planner.Registry

  require Logger

  @compiled_bundle_version 1

  defstruct [:actions, :aliases, :embeddings, :meta, :owner]

  @type t :: %__MODULE__{
          actions: :ets.tid(),
          aliases: :ets.tid(),
          embeddings: :ets.tid(),
          meta: :ets.tid(),
          owner: pid()
        }

  @impl Registry
  def new(opts \\ []) do
    registry = %__MODULE__{
      actions: :ets.new(__MODULE__, [:set, :protected]),
      aliases: :ets.new(__MODULE__, [:bag, :protected]),
      embeddings: :ets.new(__MODULE__, [:set, :protected]),
      meta: :ets.new(__MODULE__, [:set, :protected]),
      owner: self()
    }

    result =
      try do
        case maybe_load_json(registry, Keyword.get(opts, :registry_json)) do
          {:ok, registry} ->
            maybe_load_compiled(registry, Keyword.get(opts, :compiled_registry))

          {:error, _reason} = error ->
            error
        end
      rescue
        error -> {:error, {:registry_load_failed, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:registry_load_failed, {kind, reason}}}
      end

    case result do
      {:ok, registry} ->
        {:ok, registry}

      {:error, _reason} = error ->
        close(registry)
        error
    end
  end

  @impl Registry
  def owner(%__MODULE__{} = registry), do: registry.owner

  @impl Registry
  def load_json(%__MODULE__{owner: owner}, _path) when owner != self(),
    do: not_owner(owner)

  def load_json(%__MODULE__{} = registry, path) do
    with {:ok, payload} <- File.read(path),
         {:ok, decoded} <- Jason.decode(payload),
         {:ok, actions} <- json_actions(decoded),
         {:ok, actions} <- normalize_actions(actions) do
      replace_actions(registry, actions, path)
    else
      {:error, reason} -> {:error, normalize_file_error(reason)}
    end
  end

  @impl Registry
  def load_compiled(%__MODULE__{owner: owner}, _path) when owner != self(),
    do: not_owner(owner)

  def load_compiled(%__MODULE__{} = registry, path) do
    case Artifact.read_term(path) do
      {:ok, bundle} ->
        try do
          bundle
          |> normalize_compiled_bundle()
          |> install_compiled_bundle(registry, path)
        rescue
          error ->
            {:error, {:bad_etf, Exception.message(error)}}
        end

      {:error, {:invalid_artifact_term, _error} = reason} ->
        {:error, {:bad_etf, reason}}

      {:error, {:artifact_too_large, _path, _size, _limit} = reason} ->
        {:error, reason}

      {:error, {:artifact_expands_too_large, _path, _size, _limit} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:file_read, reason}}
    end
  end

  @impl Registry
  def all_actions(%__MODULE__{} = registry) do
    registry.actions
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1["id"])
  end

  @impl Registry
  def get_action(%__MODULE__{} = registry, action_id) do
    case :ets.lookup(registry.actions, action_id) do
      [{^action_id, action}] -> action
      [] -> nil
    end
  end

  @impl Registry
  def action_count(%__MODULE__{} = registry), do: :ets.info(registry.actions, :size)

  @impl Registry
  def add_action(%__MODULE__{} = registry, action) do
    upsert_action(registry, action, nil)
  end

  @impl Registry
  def upsert_action(%__MODULE__{owner: owner}, _action, _embedding) when owner != self(),
    do: not_owner(owner)

  def upsert_action(%__MODULE__{} = registry, action, embedding) do
    case Registry.normalize_action(action) do
      {:ok, normalized} ->
        replace_action(registry, normalized, embedding)
        {:ok, registry}

      {:error, _reason} = error ->
        error
    end
  end

  @impl Registry
  def delete_action(%__MODULE__{owner: owner}, _action_id) when owner != self(),
    do: not_owner(owner)

  def delete_action(%__MODULE__{} = registry, action_id) do
    existed = :ets.member(registry.actions, action_id)
    :ets.match_delete(registry.aliases, {:_, action_id, :_})
    :ets.delete(registry.embeddings, action_id)
    :ets.delete(registry.actions, action_id)
    {{:ok, existed}, registry}
  end

  @impl Registry
  def embedding_matrix(%__MODULE__{} = registry) do
    entries =
      registry.embeddings
      |> :ets.tab2list()
      |> Enum.sort_by(&elem(&1, 0))

    case entries do
      [] ->
        nil

      _ when length(entries) == action_count(registry) ->
        {ids, tensors} = Enum.unzip(entries)
        {Nx.stack(tensors), ids}

      _incomplete ->
        nil
    end
  end

  @impl Registry
  def put_embedding(%__MODULE__{owner: owner}, _action_id, _tensor) when owner != self(),
    do: not_owner(owner)

  def put_embedding(%__MODULE__{} = registry, action_id, tensor) do
    if :ets.member(registry.actions, action_id) do
      :ets.insert(registry.embeddings, {action_id, tensor})
      {:ok, registry}
    else
      {:error, :action_not_found}
    end
  end

  @impl Registry
  def tool_cards(%__MODULE__{} = registry) do
    registry
    |> all_actions()
    |> Enum.map(fn action -> {action["id"], Registry.build_tool_card(action)} end)
  end

  @impl Registry
  def resolve_alias(%__MODULE__{} = registry, alias_name) do
    alias_name
    |> String.downcase()
    |> then(&:ets.lookup(registry.aliases, &1))
    |> Enum.map(fn {_key, action_id, canonical} -> {action_id, canonical} end)
  end

  @impl Registry
  def close(%__MODULE__{} = registry) do
    cond do
      closed?(registry) ->
        :ok

      registry.owner != self() ->
        not_owner(registry.owner)

      true ->
        Enum.each(registry_tables(registry), fn table ->
          if :ets.info(table) != :undefined, do: :ets.delete(table)
        end)

        :ok
    end
  end

  defp maybe_load_json(registry, nil), do: {:ok, registry}
  defp maybe_load_json(registry, path), do: load_json(registry, path)

  defp maybe_load_compiled(registry, nil), do: {:ok, registry}
  defp maybe_load_compiled(registry, path), do: load_compiled(registry, path)

  defp registry_tables(registry) do
    [registry.actions, registry.aliases, registry.embeddings, registry.meta]
  end

  defp closed?(registry) do
    Enum.all?(registry_tables(registry), &(:ets.info(&1) == :undefined))
  end

  defp not_owner(owner), do: {:error, {:registry_not_owner, owner}}

  defp clear_tables(%__MODULE__{} = registry) do
    :ets.delete_all_objects(registry.actions)
    :ets.delete_all_objects(registry.aliases)
    :ets.delete_all_objects(registry.embeddings)
    :ets.delete_all_objects(registry.meta)
  end

  defp insert_action(%__MODULE__{} = registry, action) do
    replace_action(registry, action, nil)
  end

  defp replace_action(%__MODULE__{} = registry, action, embedding) do
    action_id = action["id"]

    :ets.match_delete(registry.aliases, {:_, action_id, :_})
    :ets.delete(registry.embeddings, action_id)
    :ets.insert(registry.actions, {action_id, action})
    index_aliases(registry.aliases, action)

    if not is_nil(embedding) do
      :ets.insert(registry.embeddings, {action_id, embedding})
    end
  end

  defp index_aliases(aliases_tab, action) do
    action_id = action["id"]

    for arg <- action["args"] || [] do
      canonical = arg["name"]
      :ets.insert(aliases_tab, {String.downcase(canonical), action_id, canonical})

      for alias_name <- arg["aliases"] || [] do
        :ets.insert(aliases_tab, {String.downcase(alias_name), action_id, canonical})
      end
    end
  end

  defp normalize_file_error(reason), do: reason

  defp json_actions(decoded) when is_map(decoded) do
    actions = Map.get(decoded, "actions", Map.get(decoded, "tools", []))

    if is_list(actions), do: {:ok, actions}, else: {:error, :invalid_registry_actions}
  end

  defp json_actions(_decoded), do: {:error, :invalid_registry}

  defp normalize_actions(actions) when is_list(actions) do
    actions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, normalized} ->
      case Registry.normalize_action(raw) do
        {:ok, action} -> {:cont, {:ok, [action | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_action, index, reason}}}
      end
    end)
    |> then(fn
      {:ok, normalized} -> validate_unique_action_ids(Enum.reverse(normalized))
      {:error, _reason} = error -> error
    end)
  end

  defp normalize_actions(_actions), do: {:error, :invalid_registry_actions}

  defp validate_unique_action_ids(actions) do
    duplicate_id =
      actions
      |> Enum.frequencies_by(& &1["id"])
      |> Enum.find_value(fn
        {id, count} when count > 1 -> id
        _entry -> nil
      end)

    if duplicate_id do
      {:error, {:duplicate_action_id, duplicate_id}}
    else
      {:ok, actions}
    end
  end

  defp normalize_compiled_bundle(bundle) when is_map(bundle) do
    with {:ok, version} <- fetch_bundle_field(bundle, :version),
         :ok <- validate_bundle_version(version),
         {:ok, raw_actions} <- fetch_bundle_field(bundle, :actions),
         {:ok, actions} <- normalize_actions(raw_actions),
         {:ok, embedding_entries} <- compiled_embedding_entries(bundle, actions) do
      {:ok, actions, embedding_entries}
    end
  end

  defp normalize_compiled_bundle(_bundle), do: {:error, :invalid_bundle}

  defp fetch_bundle_field(bundle, key) do
    case Map.fetch(bundle, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_bundle_field, key}}
    end
  end

  defp validate_bundle_version(@compiled_bundle_version), do: :ok

  defp validate_bundle_version(version),
    do: {:error, {:unsupported_bundle_version, version, @compiled_bundle_version}}

  defp compiled_embedding_entries(bundle, actions) do
    embeddings = Map.get(bundle, :tool_embeddings, [])
    action_ids = Map.get(bundle, :action_ids, [])
    known_ids = actions |> Enum.map(& &1["id"]) |> MapSet.new()

    cond do
      not is_list(embeddings) or not is_list(action_ids) ->
        {:error, :invalid_embedding_entries}

      length(embeddings) != length(action_ids) ->
        {:error, :embedding_count_mismatch}

      Enum.any?(action_ids, &(not is_binary(&1))) ->
        {:error, :invalid_embedding_action_id}

      length(Enum.uniq(action_ids)) != length(action_ids) ->
        {:error, :duplicate_embedding_action}

      Enum.any?(action_ids, fn action_id -> not MapSet.member?(known_ids, action_id) end) ->
        {:error, :unknown_embedding_action}

      true ->
        validate_compiled_embeddings(embeddings, action_ids, Map.get(bundle, :embedding_dim))
    end
  end

  defp validate_compiled_embeddings([], [], embedding_dim)
       when is_nil(embedding_dim) or
              (is_integer(embedding_dim) and embedding_dim > 0),
       do: {:ok, []}

  defp validate_compiled_embeddings(embeddings, action_ids, embedding_dim)
       when is_integer(embedding_dim) and embedding_dim > 0 do
    case Enum.find_index(embeddings, &(not valid_embedding?(&1, embedding_dim))) do
      nil -> {:ok, Enum.zip(embeddings, action_ids)}
      index -> {:error, {:invalid_embedding, index, embedding_dim}}
    end
  end

  defp validate_compiled_embeddings(_embeddings, _action_ids, embedding_dim),
    do: {:error, {:invalid_embedding_dim, embedding_dim}}

  defp valid_embedding?(%Nx.Tensor{} = tensor, embedding_dim),
    do: Nx.shape(tensor) == {embedding_dim}

  defp valid_embedding?(_embedding, _embedding_dim), do: false

  defp install_compiled_bundle(
         {:ok, actions, embedding_entries},
         registry,
         path
       ) do
    clear_tables(registry)
    Enum.each(actions, &insert_action(registry, &1))

    Enum.each(embedding_entries, fn {embedding, action_id} ->
      :ets.insert(registry.embeddings, {action_id, embedding})
    end)

    Logger.info("Planner ETS registry loaded #{action_count(registry)} actions from #{path}")
    {:ok, registry}
  end

  defp install_compiled_bundle({:error, _reason} = error, _registry, _path), do: error

  defp replace_actions(registry, actions, path) do
    clear_tables(registry)
    Enum.each(actions, &insert_action(registry, &1))

    Logger.info("Planner ETS registry loaded #{action_count(registry)} actions from #{path}")
    {:ok, registry}
  end
end
