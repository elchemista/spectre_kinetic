defmodule SpectreKinetic.Server do
  @moduledoc """
  GenServer that owns the Rust NIF resource handle.

  Wraps the opaque Rustler ResourceArc returned by `Native.open/2` and
  serialises calls through a single process so the Mutex inside the Rust
  handle is never contended from multiple BEAM schedulers at once.
  """

  use GenServer

  alias SpectreKinetic.Native

  require Logger

  # ------------------------------------------------------------------
  # Client API
  # ------------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec plan(GenServer.server(), binary()) :: {:ok, map()} | {:error, term()}
  def plan(server, al_text) do
    GenServer.call(server, {:plan, al_text})
  end

  @spec plan_json(GenServer.server(), binary()) :: {:ok, map()} | {:error, term()}
  def plan_json(server, request_json) do
    GenServer.call(server, {:plan_json, request_json})
  end

  @spec add_action(GenServer.server(), map()) :: :ok | {:error, term()}
  def add_action(server, action) do
    GenServer.call(server, {:add_action, action})
  end

  @spec delete_action(GenServer.server(), binary()) :: {:ok, boolean()} | {:error, term()}
  def delete_action(server, action_id) do
    GenServer.call(server, {:delete_action, action_id})
  end

  @spec reload_registry(GenServer.server(), binary()) :: :ok | {:error, term()}
  def reload_registry(server, registry_path) do
    GenServer.call(server, {:reload_registry, registry_path})
  end

  @spec action_count(GenServer.server()) :: non_neg_integer()
  def action_count(server) do
    GenServer.call(server, :action_count)
  end

  # ------------------------------------------------------------------
  # Server callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    model_dir = Keyword.fetch!(opts, :model_dir)
    registry_mcr = Keyword.fetch!(opts, :registry_mcr)

    Logger.info("SpectreKinetic.Server starting model=#{model_dir} registry=#{registry_mcr}")

    case Native.open(model_dir, registry_mcr) do
      handle when is_reference(handle) ->
        Logger.info("SpectreKinetic.Server ready (#{Native.action_count(handle)} actions)")
        {:ok, %{handle: handle}}

      {:error, reason} ->
        {:stop, {:nif_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:plan, al_text}, _from, state) do
    result = decode_nif_json(Native.plan(state.handle, al_text))
    {:reply, result, state}
  end

  def handle_call({:plan_json, request_json}, _from, state) do
    result = decode_nif_json(Native.plan_json(state.handle, request_json))
    {:reply, result, state}
  end

  def handle_call({:add_action, action}, _from, state) do
    case Jason.encode(action) do
      {:ok, json} ->
        case Native.add_action(state.handle, json) do
          true -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, {:json_encode, reason}}, state}
    end
  end

  def handle_call({:delete_action, action_id}, _from, state) do
    case Native.delete_action(state.handle, action_id) do
      deleted when is_boolean(deleted) -> {:reply, {:ok, deleted}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reload_registry, registry_path}, _from, state) do
    case Native.load_registry(state.handle, registry_path) do
      true -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:action_count, _from, state) do
    {:reply, Native.action_count(state.handle), state}
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp decode_nif_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, {:json_decode, reason}}
    end
  end

  defp decode_nif_json({:error, reason}), do: {:error, reason}
end
