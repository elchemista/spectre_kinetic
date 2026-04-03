defmodule SpectreKinetic.Planner.RegistryStore do
  @moduledoc """
  Compatibility `GenServer` wrapper around a planner registry backend.

  The library-first planner can use the registry backend directly, but the
  existing server/tests still use this wrapper so the old process-oriented API
  continues to work.
  """

  use GenServer

  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Planner.Registry.ETS

  @type t :: GenServer.server()

  @doc """
  Starts the registry store process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Loads a registry from a JSON file path into the store.
  """
  @spec load_json(t(), binary()) :: :ok | {:error, term()}
  def load_json(store \\ __MODULE__, path), do: GenServer.call(store, {:load_json, path})

  @doc """
  Loads a precompiled ETF registry bundle.
  """
  @spec load_compiled(t(), binary()) :: :ok | {:error, term()}
  def load_compiled(store \\ __MODULE__, path), do: GenServer.call(store, {:load_compiled, path})

  @doc """
  Returns all action definitions as a list of maps.
  """
  @spec all_actions(t()) :: [map()]
  def all_actions(store \\ __MODULE__), do: GenServer.call(store, :all_actions)

  @doc """
  Returns one action definition by ID.
  """
  @spec get_action(t(), binary()) :: map() | nil
  def get_action(store \\ __MODULE__, action_id),
    do: GenServer.call(store, {:get_action, action_id})

  @doc """
  Returns the number of loaded actions.
  """
  @spec action_count(t()) :: non_neg_integer()
  def action_count(store \\ __MODULE__), do: GenServer.call(store, :action_count)

  @doc """
  Adds one action definition to the live registry.
  """
  @spec add_action(t(), map()) :: :ok | {:error, term()}
  def add_action(store \\ __MODULE__, action), do: GenServer.call(store, {:add_action, action})

  @doc """
  Removes one action by ID.
  """
  @spec delete_action(t(), binary()) :: {:ok, boolean()} | {:error, term()}
  def delete_action(store \\ __MODULE__, action_id),
    do: GenServer.call(store, {:delete_action, action_id})

  @doc """
  Returns the precomputed embedding matrix and action-id order.
  """
  @spec embedding_matrix(t()) :: {Nx.Tensor.t(), [binary()]} | nil
  def embedding_matrix(store \\ __MODULE__), do: GenServer.call(store, :embedding_matrix)

  @doc """
  Stores a precomputed embedding for an action.
  """
  @spec put_embedding(t(), binary(), Nx.Tensor.t()) :: :ok | {:error, term()}
  def put_embedding(store \\ __MODULE__, action_id, tensor),
    do: GenServer.call(store, {:put_embedding, action_id, tensor})

  @doc """
  Returns all tool cards as `[{action_id, card_text}]`.
  """
  @spec tool_cards(t()) :: [{binary(), binary()}]
  def tool_cards(store \\ __MODULE__), do: GenServer.call(store, :tool_cards)

  @doc """
  Resolves an arg alias to action/canonical arg pairs.
  """
  @spec resolve_alias(t(), binary()) :: [{binary(), binary()}]
  def resolve_alias(store \\ __MODULE__, alias_name),
    do: GenServer.call(store, {:resolve_alias, alias_name})

  @doc false
  @spec build_tool_card(map()) :: binary()
  def build_tool_card(action), do: Registry.build_tool_card(action)

  @impl true
  def init(opts) do
    registry_module = Keyword.get(opts, :registry_module, ETS)

    case registry_module.new(opts) do
      {:ok, registry} ->
        {:ok, %{registry_module: registry_module, registry: registry}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:load_json, path}, _from, state) do
    reply_with_registry_update(state, fn module, registry -> module.load_json(registry, path) end)
  end

  def handle_call({:load_compiled, path}, _from, state) do
    reply_with_registry_update(state, fn module, registry ->
      module.load_compiled(registry, path)
    end)
  end

  def handle_call(:all_actions, _from, state) do
    {:reply, state.registry_module.all_actions(state.registry), state}
  end

  def handle_call({:get_action, action_id}, _from, state) do
    {:reply, state.registry_module.get_action(state.registry, action_id), state}
  end

  def handle_call(:action_count, _from, state) do
    {:reply, state.registry_module.action_count(state.registry), state}
  end

  def handle_call({:add_action, action}, _from, state) do
    case state.registry_module.add_action(state.registry, action) do
      {:ok, registry} -> {:reply, :ok, %{state | registry: registry}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:delete_action, action_id}, _from, state) do
    case state.registry_module.delete_action(state.registry, action_id) do
      {{:ok, deleted}, registry} ->
        {:reply, {:ok, deleted}, %{state | registry: registry}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:embedding_matrix, _from, state) do
    {:reply, state.registry_module.embedding_matrix(state.registry), state}
  end

  def handle_call({:put_embedding, action_id, tensor}, _from, state) do
    case state.registry_module.put_embedding(state.registry, action_id, tensor) do
      {:ok, registry} -> {:reply, :ok, %{state | registry: registry}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:tool_cards, _from, state) do
    {:reply, state.registry_module.tool_cards(state.registry), state}
  end

  def handle_call({:resolve_alias, alias_name}, _from, state) do
    {:reply, state.registry_module.resolve_alias(state.registry, alias_name), state}
  end

  @impl true
  def terminate(_reason, state) do
    state.registry_module.close(state.registry)
    :ok
  end

  defp reply_with_registry_update(state, loader) do
    case loader.(state.registry_module, state.registry) do
      {:ok, registry} ->
        {:reply, :ok, %{state | registry: registry}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end
end
