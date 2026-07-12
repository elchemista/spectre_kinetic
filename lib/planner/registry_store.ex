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
  @typep state :: %{required(:registry_module) => module(), required(:registry) => term()}

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
  @spec load_json(t(), term()) :: :ok | {:error, term()}
  def load_json(store \\ __MODULE__, path), do: GenServer.call(store, {:load_json, path})

  @doc """
  Loads a precompiled ETF registry bundle.
  """
  @spec load_compiled(t(), term()) :: :ok | {:error, term()}
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
  @spec resolve_alias(t(), term()) :: [{binary(), binary()}] | {:error, term()}
  def resolve_alias(store \\ __MODULE__, alias_name),
    do: GenServer.call(store, {:resolve_alias, alias_name})

  @doc false
  @spec build_tool_card(map()) :: binary()
  def build_tool_card(action), do: Registry.build_tool_card(action)

  @impl GenServer
  def init(opts) do
    registry_module = Keyword.get(opts, :registry_module, ETS)

    case safe_backend_call(fn -> registry_module.new(opts) end) do
      {:ok, {:ok, registry}} ->
        {:ok, %{registry_module: registry_module, registry: registry}}

      {:ok, {:error, reason}} ->
        {:stop, reason}

      {:ok, other} ->
        {:stop, {:invalid_registry_return, :new, other}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:load_json, path}, _from, state) do
    case validate_registry_path(path) do
      :ok ->
        reply_with_registry_update(state, :load_json, fn module, registry ->
          module.load_json(registry, path)
        end)

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:load_compiled, path}, _from, state) do
    case validate_registry_path(path) do
      :ok ->
        reply_with_registry_update(state, :load_compiled, fn module, registry ->
          module.load_compiled(registry, path)
        end)

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:all_actions, _from, state) do
    reply_with_registry_read(state, :all_actions, fn module, registry ->
      module.all_actions(registry)
    end)
  end

  def handle_call({:get_action, action_id}, _from, state) do
    reply_with_registry_read(state, :get_action, fn module, registry ->
      module.get_action(registry, action_id)
    end)
  end

  def handle_call(:action_count, _from, state) do
    reply_with_registry_read(state, :action_count, fn module, registry ->
      module.action_count(registry)
    end)
  end

  def handle_call({:add_action, action}, _from, state) do
    reply_with_registry_update(state, :add_action, fn module, registry ->
      module.add_action(registry, action)
    end)
  end

  def handle_call({:delete_action, action_id}, _from, state) do
    result =
      safe_backend_call(fn ->
        state.registry_module.delete_action(state.registry, action_id)
      end)

    case result do
      {:ok, {{:ok, deleted}, registry}} when is_boolean(deleted) ->
        {:reply, {:ok, deleted}, %{state | registry: registry}}

      {:ok, {:error, _reason} = error} ->
        {:reply, error, state}

      {:ok, other} ->
        {:reply, {:error, {:invalid_registry_return, :delete_action, other}}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:embedding_matrix, _from, state) do
    reply_with_registry_read(state, :embedding_matrix, fn module, registry ->
      module.embedding_matrix(registry)
    end)
  end

  def handle_call({:put_embedding, action_id, tensor}, _from, state) do
    reply_with_registry_update(state, :put_embedding, fn module, registry ->
      module.put_embedding(registry, action_id, tensor)
    end)
  end

  def handle_call(:tool_cards, _from, state) do
    reply_with_registry_read(state, :tool_cards, fn module, registry ->
      module.tool_cards(registry)
    end)
  end

  def handle_call({:resolve_alias, alias_name}, _from, state) do
    if is_binary(alias_name) and String.valid?(alias_name) and byte_size(alias_name) <= 256 do
      reply_with_registry_read(state, :resolve_alias, fn module, registry ->
        module.resolve_alias(registry, alias_name)
      end)
    else
      {:reply, {:error, {:invalid_registry_input, :alias}}, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    safe_backend_call(fn -> state.registry_module.close(state.registry) end)
    :ok
  end

  @spec reply_with_registry_update(state(), atom(), (module(), term() -> term())) ::
          {:reply, :ok | {:error, term()}, state()}
  defp reply_with_registry_update(state, operation, callback) do
    case safe_backend_call(fn -> callback.(state.registry_module, state.registry) end) do
      {:ok, {:ok, registry}} ->
        {:reply, :ok, %{state | registry: registry}}

      {:ok, {:error, _reason} = error} ->
        {:reply, error, state}

      {:ok, other} ->
        {:reply, {:error, {:invalid_registry_return, operation, other}}, state}

      {:error, reason} ->
        {:reply, {:error, {:registry_backend_failed, operation, reason}}, state}
    end
  end

  @spec reply_with_registry_read(state(), atom(), (module(), term() -> term())) ::
          {:reply, term(), state()}
  defp reply_with_registry_read(state, operation, callback) do
    case safe_backend_call(fn -> callback.(state.registry_module, state.registry) end) do
      {:ok, value} -> {:reply, value, state}
      {:error, reason} -> {:reply, {:error, {:registry_backend_failed, operation, reason}}, state}
    end
  end

  # Registry backends are extension points. A faulty backend must produce a
  # structured error instead of terminating this compatibility server.
  @spec safe_backend_call((-> result)) :: {:ok, result} | {:error, term()} when result: term()
  defp safe_backend_call(callback) do
    {:ok, callback.()}
  rescue
    error -> {:error, {:raise, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec validate_registry_path(term()) :: :ok | {:error, {:invalid_registry_input, :path}}
  defp validate_registry_path(path) when is_binary(path) do
    if String.valid?(path) and byte_size(path) <= 4_096 and String.trim(path) != "" and
         not String.contains?(path, <<0>>),
      do: :ok,
      else: {:error, {:invalid_registry_input, :path}}
  end

  defp validate_registry_path(_path), do: {:error, {:invalid_registry_input, :path}}
end
