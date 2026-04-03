defmodule SpectreKinetic.Server do
  @moduledoc """
  Thin `GenServer` adapter over the library-first planner runtime.
  """

  use GenServer

  alias SpectreKinetic.Action
  alias SpectreKinetic.Planner
  alias SpectreKinetic.Planner.Runtime, as: PlannerRuntime
  alias SpectreKinetic.Runtime

  require Logger

  @doc """
  Starts the supervised server that owns one planner runtime.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Plans one AL instruction through the server process.
  """
  @spec plan(GenServer.server(), binary(), keyword()) :: {:ok, Action.t()} | {:error, term()}
  def plan(server, al_text, opts \\ []), do: GenServer.call(server, {:plan, al_text, opts})

  @doc """
  Plans from an explicit request map.
  """
  @spec plan_request(GenServer.server(), map()) :: {:ok, Action.t()} | {:error, term()}
  def plan_request(server, request), do: GenServer.call(server, {:plan_request, request})

  @doc """
  Plans from a JSON-encoded request payload.
  """
  @spec plan_json(GenServer.server(), binary()) :: {:ok, Action.t()} | {:error, term()}
  def plan_json(server, request_json), do: GenServer.call(server, {:plan_json, request_json})

  @doc """
  Adds one tool definition to the active registry.
  """
  @spec add_action(GenServer.server(), map()) :: :ok | {:error, term()}
  def add_action(server, action), do: GenServer.call(server, {:add_action, action})

  @doc """
  Deletes one tool definition by id from the active registry.
  """
  @spec delete_action(GenServer.server(), binary()) :: {:ok, boolean()} | {:error, term()}
  def delete_action(server, action_id), do: GenServer.call(server, {:delete_action, action_id})

  @doc """
  Reloads the registry from disk.
  """
  @spec reload_registry(GenServer.server(), binary()) :: :ok | {:error, term()}
  def reload_registry(server, registry_path),
    do: GenServer.call(server, {:reload_registry, registry_path})

  @doc """
  Returns the number of active tools in the current registry.
  """
  @spec action_count(GenServer.server()) :: non_neg_integer()
  def action_count(server), do: GenServer.call(server, :action_count)

  @impl true
  def init(opts) do
    case PlannerRuntime.load(opts) do
      {:ok, runtime} ->
        Logger.info(
          "SpectreKinetic.Server ready (#{PlannerRuntime.action_count(runtime)} actions)"
        )

        {:ok, %{runtime: runtime}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:plan, al_text, opts}, _from, state) do
    {:reply, do_plan(state.runtime, al_text, opts), state}
  end

  def handle_call({:plan_request, request}, _from, state) do
    al_text = Map.get(request, :al) || Map.get(request, "al") || ""

    reply =
      case Planner.plan_request(normalize_request(request), PlannerRuntime.plan_opts(state.runtime)) do
        {:ok, plan_map} -> {:ok, Action.from_plan(al_text, plan_map)}
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:plan_json, request_json}, _from, state) do
    reply =
      with {:ok, request} <- Jason.decode(request_json),
           normalized <- normalize_request(request),
           {:ok, plan_map} <- Planner.plan_request(normalized, PlannerRuntime.plan_opts(state.runtime)) do
        {:ok, Action.from_plan(normalized["al"], plan_map)}
      else
        {:error, reason} -> {:error, {:json_decode, reason}}
      end

    {:reply, reply, state}
  end

  def handle_call({:add_action, action}, _from, state) do
    case PlannerRuntime.add_action(state.runtime, action) do
      {:ok, runtime} -> {:reply, :ok, %{state | runtime: runtime}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:delete_action, action_id}, _from, state) do
    case PlannerRuntime.delete_action(state.runtime, action_id) do
      {:ok, deleted, runtime} -> {:reply, {:ok, deleted}, %{state | runtime: runtime}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:reload_registry, registry_path}, _from, state) do
    case PlannerRuntime.reload_registry(state.runtime, registry_path) do
      {:ok, runtime} -> {:reply, :ok, %{state | runtime: runtime}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:action_count, _from, state) do
    {:reply, PlannerRuntime.action_count(state.runtime), state}
  end

  defp do_plan(runtime, al_text, opts) do
    with {:ok, plan_map} <- Planner.plan(runtime, al_text, opts) do
      {:ok, Action.from_plan(al_text, plan_map)}
    end
  end

  defp normalize_request(request) do
    %{
      "al" => Map.get(request, :al) || Map.get(request, "al") || "",
      "slots" =>
        request
        |> Map.get(:slots, Map.get(request, "slots", %{}))
        |> Runtime.stringify_map(),
      "top_k" => Map.get(request, :top_k) || Map.get(request, "top_k") || 5
    }
    |> maybe_put("tool_threshold", Map.get(request, :tool_threshold) || Map.get(request, "tool_threshold"))
    |> maybe_put(
      "mapping_threshold",
      Map.get(request, :mapping_threshold) || Map.get(request, "mapping_threshold")
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
