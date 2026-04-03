defmodule SpectreKinetic.Planner.Registry.ETS do
  @moduledoc """
  Default ETS-backed registry backend for the Elixir planner runtime.
  """

  @behaviour SpectreKinetic.Planner.Registry

  alias SpectreKinetic.Planner.Registry

  require Logger

  defstruct [:actions, :aliases, :embeddings, :meta]

  @type t :: %__MODULE__{
          actions: :ets.tid(),
          aliases: :ets.tid(),
          embeddings: :ets.tid(),
          meta: :ets.tid()
        }

  @impl true
  def new(opts \\ []) do
    registry = %__MODULE__{
      actions: :ets.new(__MODULE__, [:set, :protected]),
      aliases: :ets.new(__MODULE__, [:bag, :protected]),
      embeddings: :ets.new(__MODULE__, [:set, :protected]),
      meta: :ets.new(__MODULE__, [:set, :protected])
    }

    case maybe_load_json(registry, Keyword.get(opts, :registry_json)) do
      {:ok, registry} -> maybe_load_compiled(registry, Keyword.get(opts, :compiled_registry))
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def load_json(%__MODULE__{} = registry, path) do
    with {:ok, payload} <- File.read(path),
         {:ok, decoded} <- Jason.decode(payload) do
      decoded
      |> Map.get("actions", Map.get(decoded, "tools", []))
      |> reload_actions(registry, path)
    else
      {:error, reason} -> {:error, normalize_file_error(reason)}
    end
  end

  @impl true
  def load_compiled(%__MODULE__{} = registry, path) do
    case File.read(path) do
      {:ok, binary} ->
        try do
          bundle = :erlang.binary_to_term(binary)
          clear_tables(registry)

          bundle
          |> Map.fetch!(:actions)
          |> Enum.each(&insert_action(registry, &1))

          bundle
          |> Map.get(:tool_embeddings, [])
          |> Enum.zip(Map.get(bundle, :action_ids, []))
          |> Enum.each(fn {embedding, action_id} ->
            :ets.insert(registry.embeddings, {action_id, embedding})
          end)

          Logger.info(
            "Planner ETS registry loaded #{action_count(registry)} actions from #{path}"
          )

          {:ok, registry}
        rescue
          error ->
            {:error, {:bad_etf, Exception.message(error)}}
        end

      {:error, reason} ->
        {:error, {:file_read, reason}}
    end
  end

  @impl true
  def all_actions(%__MODULE__{} = registry) do
    registry.actions
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1["id"])
  end

  @impl true
  def get_action(%__MODULE__{} = registry, action_id) do
    case :ets.lookup(registry.actions, action_id) do
      [{^action_id, action}] -> action
      [] -> nil
    end
  end

  @impl true
  def action_count(%__MODULE__{} = registry), do: :ets.info(registry.actions, :size)

  @impl true
  def add_action(%__MODULE__{} = registry, action) do
    case Registry.normalize_action(action) do
      {:ok, normalized} ->
        insert_action(registry, normalized)
        {:ok, registry}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def delete_action(%__MODULE__{} = registry, action_id) do
    existed = :ets.member(registry.actions, action_id)
    :ets.delete(registry.actions, action_id)
    :ets.delete(registry.embeddings, action_id)
    :ets.match_delete(registry.aliases, {:_, action_id, :_})
    {{:ok, existed}, registry}
  end

  @impl true
  def embedding_matrix(%__MODULE__{} = registry) do
    entries =
      registry.embeddings
      |> :ets.tab2list()
      |> Enum.sort_by(&elem(&1, 0))

    case entries do
      [] ->
        nil

      _ ->
        {ids, tensors} = Enum.unzip(entries)
        {Nx.stack(tensors), ids}
    end
  end

  @impl true
  def put_embedding(%__MODULE__{} = registry, action_id, tensor) do
    :ets.insert(registry.embeddings, {action_id, tensor})
    {:ok, registry}
  end

  @impl true
  def tool_cards(%__MODULE__{} = registry) do
    registry
    |> all_actions()
    |> Enum.map(fn action -> {action["id"], Registry.build_tool_card(action)} end)
  end

  @impl true
  def resolve_alias(%__MODULE__{} = registry, alias_name) do
    alias_name
    |> String.downcase()
    |> then(&:ets.lookup(registry.aliases, &1))
    |> Enum.map(fn {_key, action_id, canonical} -> {action_id, canonical} end)
  end

  @impl true
  def close(%__MODULE__{} = registry) do
    Enum.each(
      [registry.actions, registry.aliases, registry.embeddings, registry.meta],
      fn table ->
        if :ets.info(table) != :undefined do
          :ets.delete(table)
        end
      end
    )

    :ok
  end

  defp maybe_load_json(registry, nil), do: {:ok, registry}
  defp maybe_load_json(registry, path), do: load_json(registry, path)

  defp maybe_load_compiled(registry, nil), do: {:ok, registry}
  defp maybe_load_compiled(registry, path), do: load_compiled(registry, path)

  defp clear_tables(%__MODULE__{} = registry) do
    :ets.delete_all_objects(registry.actions)
    :ets.delete_all_objects(registry.aliases)
    :ets.delete_all_objects(registry.embeddings)
    :ets.delete_all_objects(registry.meta)
  end

  defp insert_action(%__MODULE__{} = registry, action) do
    :ets.insert(registry.actions, {action["id"], action})
    index_aliases(registry.aliases, action)
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

  defp reload_actions(actions, registry, path) do
    clear_tables(registry)

    Enum.each(actions, fn raw ->
      insert_normalized_action(registry, raw, path)
    end)

    Logger.info("Planner ETS registry loaded #{action_count(registry)} actions from #{path}")
    {:ok, registry}
  end

  defp insert_normalized_action(registry, raw, path) do
    case Registry.normalize_action(raw) do
      {:ok, action} ->
        insert_action(registry, action)

      {:error, reason} ->
        Logger.warning("Skipping invalid action from #{path}: #{inspect(reason)}")
    end
  end
end
