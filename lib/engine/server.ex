defmodule SpectreKinetic.Server do
  @moduledoc """
  GenServer that owns the Rust resource handle.
  """

  use GenServer

  alias SpectreKinetic.Action
  alias SpectreKinetic.Native
  alias SpectreKinetic.Parser
  alias SpectreKinetic.Runtime

  require Logger

  @plan_keys [:slots, :top_k, :tool_threshold, :mapping_threshold]

  @doc """
  Starts the supervised server that owns the Rust planner resource.
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
  Reloads the compiled registry from disk.
  """
  @spec reload_registry(GenServer.server(), binary()) :: :ok | {:error, term()}
  def reload_registry(server, registry_path),
    do: GenServer.call(server, {:reload_registry, registry_path})

  @doc """
  Returns the number of active tools in the current registry.
  """
  @spec action_count(GenServer.server()) :: non_neg_integer()
  def action_count(server), do: GenServer.call(server, :action_count)

  @doc false
  @spec init(keyword()) :: {:ok, map()} | {:stop, term()}
  @impl true
  def init(opts) do
    with {:ok, %{model_dir: model_dir, registry_mcr: registry_mcr}} <- resolve_config(opts),
         {:ok, handle} <- open_handle(model_dir, registry_mcr) do
      Logger.info("SpectreKinetic.Server starting model=#{model_dir} registry=#{registry_mcr}")
      Logger.info("SpectreKinetic.Server ready (#{Native.action_count(handle)} actions)")
      {:ok, %{handle: handle, model_dir: model_dir, registry_mcr: registry_mcr}}
    else
      {:error, {:invalid_config, reason}} ->
        {:stop, {:invalid_config, Runtime.missing_path_message(reason)}}

      {:error, {:nif_open_failed, reason}} ->
        {:stop, {:nif_open_failed, reason}}
    end
  end

  @doc false
  @spec handle_call(term(), GenServer.from(), map()) :: {:reply, term(), map()}
  @impl true
  def handle_call({:plan, al_text, opts}, _from, state) do
    {:reply, plan_result(state.handle, al_text, opts), state}
  end

  def handle_call({:plan_request, request}, _from, state) do
    normalized = normalize_request(request)

    result =
      normalized
      |> Jason.encode()
      |> case do
        {:ok, json} -> decode_plan(Native.plan_json(state.handle, json), normalized["al"])
        {:error, reason} -> {:error, {:json_encode, reason}}
      end

    {:reply, result, state}
  end

  def handle_call({:plan_json, request_json}, _from, state) do
    result =
      with {:ok, request} <- Jason.decode(request_json),
           normalized <- normalize_request(request),
           {:ok, json} <- Jason.encode(normalized) do
        decode_plan(Native.plan_json(state.handle, json), normalized["al"])
      else
        {:error, reason} -> {:error, {:json_decode, reason}}
      end

    {:reply, result, state}
  end

  def handle_call({:add_action, action}, _from, state) do
    reply =
      case Jason.encode(action) do
        {:ok, json} ->
          case Native.add_action(state.handle, json) do
            true -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, {:json_encode, reason}}
      end

    {:reply, reply, state}
  end

  def handle_call({:delete_action, action_id}, _from, state) do
    reply =
      case Native.delete_action(state.handle, action_id) do
        deleted when is_boolean(deleted) -> {:ok, deleted}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:reload_registry, registry_path}, _from, state) do
    reply =
      case Native.load_registry(state.handle, registry_path) do
        true -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, %{state | registry_mcr: registry_path}}
  end

  def handle_call(:action_count, _from, state) do
    {:reply, Native.action_count(state.handle), state}
  end

  defp simple_plan?(opts) do
    Enum.all?(@plan_keys, &simple_plan_option?(&1, Keyword.get(opts, &1)))
  end

  defp build_request(opts, al_text) do
    opts = effective_plan_opts(opts)

    %{
      "al" => al_text,
      "slots" => build_slots(opts, al_text),
      "top_k" => Keyword.get(opts, :top_k, 5),
      "tool_threshold" => Keyword.get(opts, :tool_threshold),
      "mapping_threshold" => Keyword.get(opts, :mapping_threshold)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_request(request) do
    defaults = Runtime.default_plan_options() |> Map.new()

    %{
      "al" => Map.get(request, :al) || Map.get(request, "al") || "",
      "slots" =>
        request
        |> Map.get(:slots, Map.get(request, "slots", %{}))
        |> Runtime.stringify_map(),
      "top_k" => Map.get(request, :top_k) || Map.get(request, "top_k") || defaults[:top_k] || 5
    }
    |> maybe_put(
      "tool_threshold",
      threshold_from_request(request) || defaults[:tool_threshold]
    )
    |> maybe_put(
      "mapping_threshold",
      Map.get(request, :mapping_threshold) || Map.get(request, "mapping_threshold") ||
        defaults[:mapping_threshold]
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp plan_result(handle, al_text, opts) when is_list(opts) do
    opts = effective_plan_opts(opts)

    case simple_plan?(opts) do
      true -> decode_plan(Native.plan_al(handle, al_text), al_text)
      false -> opts |> build_request(al_text) |> encode_and_plan(handle, al_text)
    end
  end

  defp encode_and_plan(request, handle, al_text) do
    case Jason.encode(request) do
      {:ok, json} -> decode_plan(Native.plan_json(handle, json), al_text)
      {:error, reason} -> {:error, {:json_encode, reason}}
    end
  end

  defp simple_plan_option?(:slots, nil), do: true
  defp simple_plan_option?(:slots, %{} = slots), do: map_size(slots) == 0
  defp simple_plan_option?(:top_k, 5), do: true
  defp simple_plan_option?(_key, nil), do: true
  defp simple_plan_option?(_key, _value), do: false

  defp effective_plan_opts(opts) do
    opts
    |> normalize_threshold_aliases()
    |> then(&Keyword.merge(Runtime.default_plan_options(), &1))
  end

  defp normalize_threshold_aliases(opts) do
    case Keyword.get(opts, :tool_threshold) || Keyword.get(opts, :confidence_threshold) ||
           Keyword.get(opts, :confidence) do
      nil -> opts
      threshold -> Keyword.put(opts, :tool_threshold, threshold)
    end
  end

  defp threshold_from_request(request) do
    Map.get(request, :tool_threshold) || Map.get(request, "tool_threshold") ||
      Map.get(request, :confidence_threshold) || Map.get(request, "confidence_threshold") ||
      Map.get(request, :confidence) || Map.get(request, "confidence")
  end

  @spec resolve_config(keyword()) ::
          {:ok, %{model_dir: binary(), registry_mcr: binary()}}
          | {:error, {:invalid_config, term()}}
  defp resolve_config(opts) do
    case Runtime.resolve_runtime_paths(opts) do
      {:ok, paths} -> {:ok, paths}
      {:error, reason} -> {:error, {:invalid_config, reason}}
    end
  end

  @spec open_handle(binary(), binary()) :: {:ok, reference()} | {:error, {:nif_open_failed, term()}}
  defp open_handle(model_dir, registry_mcr) do
    case Native.open(model_dir, registry_mcr) do
      handle when is_reference(handle) -> {:ok, handle}
      {:error, reason} -> {:error, {:nif_open_failed, reason}}
    end
  end

  defp build_slots(opts, al_text) do
    opts
    |> Keyword.get(:slots)
    |> normalize_slots(al_text)
  end

  defp normalize_slots(nil, al_text), do: Parser.slot_map(al_text)
  defp normalize_slots(provided, _al_text), do: Runtime.stringify_map(provided)

  defp decode_plan(json, al_text) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, Action.from_plan(al_text, map)}
      {:error, reason} -> {:error, {:json_decode, reason}}
    end
  end

  defp decode_plan({:error, reason}, _al_text), do: {:error, reason}
end
