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

  @compiled_bundle_version 2
  @legacy_compiled_bundle_version 1
  @f32_max 3.402_823_466_385_288_6e38
  @max_actions 1_000
  @max_embedding_dim 16_384

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
  def new_staging(%__MODULE__{}, _opts), do: new()

  @impl Registry
  def load_json(%__MODULE__{owner: owner}, _path) when owner != self(),
    do: not_owner(owner)

  def load_json(%__MODULE__{} = registry, path) when is_binary(path) do
    if valid_registry_path?(path),
      do: do_load_json(registry, path),
      else: {:error, {:invalid_registry_input, :path}}
  end

  def load_json(%__MODULE__{}, _path), do: {:error, {:invalid_registry_input, :path}}

  defp do_load_json(registry, path) do
    with {:ok, decoded} <- Artifact.read_json(path),
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

  def load_compiled(%__MODULE__{} = registry, path) when is_binary(path) do
    if valid_registry_path?(path),
      do: do_load_compiled(registry, path),
      else: {:error, {:invalid_registry_input, :path}}
  end

  def load_compiled(%__MODULE__{}, _path), do: {:error, {:invalid_registry_input, :path}}

  defp do_load_compiled(registry, path) do
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
        with :ok <- validate_embedding(registry, normalized["id"], embedding),
             :ok <- validate_action_capacity(registry, normalized["id"]) do
          replace_action(registry, normalized, embedding)
          {:ok, registry}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_action_capacity(registry, action_id) do
    if action_count(registry) >= @max_actions and
         not :ets.member(registry.actions, action_id) do
      {:error, {:too_many_actions, action_count(registry) + 1, @max_actions}}
    else
      :ok
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
  rescue
    _error -> nil
  end

  @impl Registry
  def put_embedding(%__MODULE__{owner: owner}, _action_id, _tensor) when owner != self(),
    do: not_owner(owner)

  def put_embedding(%__MODULE__{} = registry, action_id, tensor) do
    cond do
      not :ets.member(registry.actions, action_id) ->
        {:error, :action_not_found}

      true ->
        case validate_embedding(registry, action_id, tensor) do
          :ok ->
            :ets.insert(registry.embeddings, {action_id, tensor})
            {:ok, registry}

          {:error, _reason} = error ->
            error
        end
    end
  end

  @impl Registry
  def tool_cards(%__MODULE__{} = registry) do
    registry
    |> all_actions()
    |> Enum.map(fn action -> {action["id"], Registry.build_tool_card(action)} end)
  end

  @impl Registry
  def resolve_alias(%__MODULE__{} = registry, alias_name) when is_binary(alias_name) do
    if String.valid?(alias_name) and byte_size(alias_name) <= 256 do
      alias_name
      |> String.downcase()
      |> then(&:ets.lookup(registry.aliases, &1))
      |> Enum.map(fn {_key, action_id, canonical} -> {action_id, canonical} end)
    else
      []
    end
  end

  def resolve_alias(%__MODULE__{}, _alias_name), do: []

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

  defp valid_registry_path?(path) do
    String.valid?(path) and byte_size(path) <= 4_096 and String.trim(path) != "" and
      not String.contains?(path, <<0>>)
  end

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
    if length(actions) > @max_actions do
      {:error, {:too_many_actions, length(actions), @max_actions}}
    else
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
         {:ok, embedding_entries} <- compiled_embedding_entries(bundle, actions, version) do
      {:ok, actions, embedding_entries}
    end
  end

  defp normalize_compiled_bundle(_bundle), do: {:error, :invalid_bundle}

  defp fetch_bundle_field(bundle, key) do
    case Map.fetch(bundle, key) do
      {:ok, value} -> {:ok, value}
      :error ->
        case Map.fetch(bundle, Atom.to_string(key)) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, {:missing_bundle_field, key}}
        end
    end
  end

  defp validate_bundle_version(version)
       when version in [@legacy_compiled_bundle_version, @compiled_bundle_version],
       do: :ok

  defp validate_bundle_version(version),
    do: {:error, {:unsupported_bundle_version, version, @compiled_bundle_version}}

  defp compiled_embedding_entries(bundle, actions, version) do
    embeddings = bundle_value(bundle, :tool_embeddings, [])
    action_ids = bundle_value(bundle, :action_ids, [])
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

      action_ids != [] and not complete_embedding_coverage?(known_ids, action_ids) ->
        {:error, :incomplete_embedding_coverage}

      true ->
        validate_compiled_embeddings(
          embeddings,
          action_ids,
          bundle_value(bundle, :embedding_dim),
          version,
          bundle_value(bundle, :embedding_dtype)
        )
    end
  end

  defp validate_compiled_embeddings([], [], embedding_dim, _version, _dtype)
       when is_nil(embedding_dim) or
              (is_integer(embedding_dim) and embedding_dim > 0),
       do: {:ok, []}

  defp validate_compiled_embeddings(
         embeddings,
         action_ids,
         embedding_dim,
         @legacy_compiled_bundle_version,
         _dtype
       )
       when is_integer(embedding_dim) and embedding_dim > 0 and
              embedding_dim <= @max_embedding_dim do
    case Enum.find_index(embeddings, &(not valid_legacy_embedding?(&1, embedding_dim))) do
      nil -> {:ok, Enum.zip(embeddings, action_ids)}
      index -> {:error, {:invalid_embedding, index, embedding_dim}}
    end
  end

  defp validate_compiled_embeddings(
         embeddings,
         action_ids,
         embedding_dim,
         @compiled_bundle_version,
         "f32"
       )
       when is_integer(embedding_dim) and embedding_dim > 0 and
              embedding_dim <= @max_embedding_dim do
    case Enum.find_index(embeddings, &(not valid_data_embedding?(&1, embedding_dim))) do
      nil ->
        entries =
          embeddings
          |> Enum.map(&Nx.tensor(&1, type: :f32))
          |> Enum.zip(action_ids)

        {:ok, entries}

      index ->
        {:error, {:invalid_embedding, index, embedding_dim}}
    end
  end

  defp validate_compiled_embeddings(
         _embeddings,
         _action_ids,
         _embedding_dim,
         @compiled_bundle_version,
         dtype
       )
       when dtype != "f32",
       do: {:error, {:unsupported_embedding_dtype, dtype}}

  defp validate_compiled_embeddings(_embeddings, _action_ids, embedding_dim, _version, _dtype),
    do: {:error, {:invalid_embedding_dim, embedding_dim}}

  defp valid_legacy_embedding?(%Nx.Tensor{} = tensor, embedding_dim) do
    Nx.shape(tensor) == {embedding_dim} and
      floating_embedding_type?(tensor) and
      tensor |> Nx.to_flat_list() |> Enum.all?(&finite_number?/1)
  rescue
    _error -> false
  end

  defp valid_legacy_embedding?(_embedding, _embedding_dim), do: false

  defp valid_data_embedding?(embedding, embedding_dim) when is_list(embedding) do
    length(embedding) == embedding_dim and Enum.all?(embedding, &finite_f32_number?/1)
  end

  defp valid_data_embedding?(_embedding, _embedding_dim), do: false

  defp finite_number?(value) when is_integer(value), do: true

  defp finite_number?(value) when is_float(value) do
    representation = value |> :erlang.float_to_binary([:compact]) |> String.downcase()
    representation not in ["nan", "inf", "-inf"]
  rescue
    _error -> false
  end

  defp finite_number?(_value), do: false

  @spec validate_embedding(t(), binary(), term()) :: :ok | {:error, term()}
  defp validate_embedding(_registry, _action_id, nil), do: :ok

  defp validate_embedding(registry, action_id, %Nx.Tensor{} = tensor) do
    case Nx.shape(tensor) do
      {dimension} when dimension > 0 and dimension <= @max_embedding_dim ->
        with :ok <- validate_embedding_type(tensor),
             :ok <- validate_embedding_values(tensor) do
          validate_embedding_dimension(registry, action_id, dimension)
        end

      shape ->
        {:error, {:invalid_embedding_shape, shape}}
    end
  end

  defp validate_embedding(_registry, _action_id, _tensor),
    do: {:error, :invalid_embedding_tensor}

  defp validate_embedding_type(tensor) do
    if floating_embedding_type?(tensor),
      do: :ok,
      else: {:error, {:invalid_embedding_type, Nx.type(tensor)}}
  end

  defp floating_embedding_type?(tensor),
    do: match?({:f, _bits}, Nx.type(tensor)) or match?({:bf, _bits}, Nx.type(tensor))

  defp validate_embedding_values(tensor) do
    if tensor |> Nx.to_flat_list() |> Enum.all?(&finite_number?/1),
      do: :ok,
      else: {:error, :non_finite_embedding}
  rescue
    _error -> {:error, :invalid_embedding_tensor}
  end

  defp validate_embedding_dimension(registry, action_id, dimension) do
    case existing_embedding_dimension(registry, action_id) do
      nil -> :ok
      ^dimension -> :ok
      existing -> {:error, {:embedding_dimension_mismatch, dimension, existing}}
    end
  end

  defp existing_embedding_dimension(registry, excluded_action_id) do
    Enum.find_value(:ets.tab2list(registry.embeddings), fn
      {^excluded_action_id, _tensor} -> nil
      {_action_id, %Nx.Tensor{} = tensor} -> tensor_dimension(tensor)
      _invalid -> nil
    end)
  end

  defp tensor_dimension(tensor) do
    case Nx.shape(tensor) do
      {dimension} -> dimension
      _shape -> nil
    end
  end

  defp finite_f32_number?(value) when is_number(value),
    do: finite_number?(value) and abs(value) <= @f32_max

  defp finite_f32_number?(_value), do: false

  defp complete_embedding_coverage?(known_ids, action_ids),
    do: MapSet.equal?(known_ids, MapSet.new(action_ids))

  defp bundle_value(bundle, key, default \\ nil) do
    case Map.fetch(bundle, key) do
      {:ok, value} -> value
      :error -> Map.get(bundle, Atom.to_string(key), default)
    end
  end

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
