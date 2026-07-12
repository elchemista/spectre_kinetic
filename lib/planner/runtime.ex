defmodule SpectreKinetic.Planner.Runtime do
  @moduledoc """
  Library-first planner runtime.

  This runtime is a small explicit struct that holds the loaded encoder, the
  selected registry backend module, the backend handle/state, and default
  planning thresholds.
  """

  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Planner.Runtime.Embeddings
  alias SpectreKinetic.Planner.Runtime.Loader
  alias SpectreKinetic.RuntimeConfig
  alias SpectreKinetic.Telemetry

  @registry_reload_event [:spectre_kinetic, :runtime, :registry, :reload]
  @registry_add_event [:spectre_kinetic, :runtime, :registry, :add_action]
  @registry_delete_event [:spectre_kinetic, :runtime, :registry, :delete_action]

  defstruct [
    :registry_module,
    :registry,
    :encoder,
    :reranker_module,
    :reranker,
    :allow_empty_registry,
    :defaults,
    :classifiers
  ]

  @type t :: %__MODULE__{
          registry_module: module(),
          registry: term(),
          encoder: EmbeddingRuntime.runtime_t() | nil,
          reranker_module: module(),
          reranker: term() | nil,
          allow_empty_registry: boolean(),
          defaults: keyword(),
          classifiers: [module() | {module(), keyword()}]
        }

  @doc """
  Loads a runtime from the provided options.

  Supported options:

    * `:registry_module` — registry backend module, defaults to ETS
    * `:registry_json` — registry JSON source path
    * `:compiled_registry` — compiled ETF bundle path
    * `:allow_empty_registry` — explicitly permit a runtime without actions,
      defaults to `false`
    * `:encoder_model_dir` — ONNX encoder directory
    * `:top_k`, `:tool_threshold`, `:mapping_threshold` — default planner opts
    * `:tool_selection_fallback` — `:disabled` or `:reranker`
    * `:fallback_model_dir` — path to reranker ONNX directory
    * `:fallback_top_k`, `:fallback_margin`, `:reranker_threshold` — reranker fallback tuning
    * `:classifiers` — planning-time classifier pipeline specs
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    case Loader.components(opts) do
      {:ok, components} -> embed_loaded_registry(struct(__MODULE__, components), opts)
      {:error, _reason} = error -> error
    end
  end

  @spec embed_loaded_registry(t(), keyword()) :: {:ok, t()} | {:error, term()}
  defp embed_loaded_registry(runtime, opts) do
    case safely(fn -> Embeddings.embed_loaded_registry(runtime, opts) end) do
      {:ok, runtime} ->
        {:ok, runtime}

      {:error, _reason} = error ->
        close(runtime)
        error
    end
  end

  @doc """
  Loads a runtime and raises on failure.
  """
  @spec load!(keyword()) :: t()
  def load!(opts \\ []) do
    case load(opts) do
      {:ok, runtime} ->
        runtime

      {:error, reason} ->
        raise ArgumentError, "failed to load planner runtime: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the effective planner options for one call.
  """
  @spec plan_opts(t(), keyword()) :: map()
  def plan_opts(%__MODULE__{} = runtime, opts \\ []) do
    runtime.defaults
    |> Keyword.merge(opts)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.put(:registry_module, runtime.registry_module)
    |> Map.put(:registry, runtime.registry)
    |> maybe_put(:embedder, runtime.encoder)
    |> maybe_put(:reranker_module, runtime.reranker_module)
    |> maybe_put(:reranker, runtime.reranker)
  end

  @doc """
  Returns the effective per-action classifier specs for one planning call.
  """
  @spec classifiers(t(), keyword()) :: [module() | {module(), keyword()}]
  def classifiers(%__MODULE__{} = runtime, opts \\ []) do
    if Keyword.has_key?(opts, :classifiers) do
      Keyword.get(opts, :classifiers) || []
    else
      runtime.classifiers || []
    end
  end

  @doc """
  Returns the current number of actions in the runtime registry.
  """
  @spec action_count(t()) :: non_neg_integer()
  def action_count(%__MODULE__{} = runtime) do
    runtime.registry_module.action_count(runtime.registry)
  end

  @doc """
  Closes registry resources owned by the calling process.

  ETS-backed runtimes are process-owned: they may be shared for planning, but
  mutations and closure must run in the process that loaded them. Supervised
  adapter runtimes are closed automatically when their server terminates.
  """
  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{} = runtime) do
    runtime.registry_module.close(runtime.registry)
  end

  @doc """
  Reloads the runtime registry from either JSON or compiled ETF and returns the
  updated runtime.
  """
  @spec reload_registry(t(), term()) :: {:ok, t()} | {:error, term()}
  def reload_registry(%__MODULE__{} = runtime, path) do
    start = System.monotonic_time()

    {result, embedding_attempted?} =
      case RuntimeConfig.validate_path(path, :registry_path) do
        :ok -> stage_and_swap_registry(runtime, path)
        {:error, _reason} = error -> {error, false}
      end

    emit_registry_event(@registry_reload_event, start, runtime, result, %{
      path: path,
      format: registry_format(path),
      embedding_attempted: embedding_attempted?
    })

    result
  end

  @doc """
  Adds one action definition to the runtime registry and returns the updated runtime.
  """
  @spec add_action(t(), map()) :: {:ok, t()} | {:error, term()}
  def add_action(%__MODULE__{} = runtime, action) do
    start = System.monotonic_time()

    result =
      with :ok <- ensure_registry_owner(runtime),
           {:ok, action, embedding} <- Embeddings.prepare_action(runtime, action),
           {:ok, registry} <-
             Registry.upsert(runtime.registry_module, runtime.registry, action, embedding) do
        {:ok, %{runtime | registry: registry}}
      end

    emit_registry_event(@registry_add_event, start, runtime, result, %{
      action_id: action_id(action),
      embedding_attempted: not is_nil(runtime.encoder)
    })

    result
  end

  @doc """
  Deletes one action definition from the runtime registry and returns the updated runtime.
  """
  @spec delete_action(t(), binary()) :: {:ok, boolean(), t()} | {:error, term()}
  def delete_action(%__MODULE__{} = runtime, action_id) do
    start = System.monotonic_time()

    result =
      with :ok <- ensure_registry_owner(runtime) do
        case runtime.registry_module.delete_action(runtime.registry, action_id) do
          {{:ok, deleted}, registry} ->
            {:ok, deleted, %{runtime | registry: registry}}

          {:error, _reason} = error ->
            error
        end
      end

    emit_delete_event(start, runtime, result, action_id)

    result
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stage_and_swap_registry(runtime, path) do
    case ensure_registry_owner(runtime) do
      :ok ->
        do_stage_and_swap_registry(runtime, path)

      {:error, _reason} = error ->
        {error, false}
    end
  end

  defp do_stage_and_swap_registry(runtime, path) do
    opts = [allow_empty_registry: runtime.allow_empty_registry]

    case Loader.stage_registry(runtime.registry_module, runtime.registry, path, opts) do
      {:ok, registry} -> complete_staged_registry(runtime, registry, path)
      {:error, _reason} = error -> {error, false}
    end
  end

  defp complete_staged_registry(runtime, registry, path) do
    case safely(fn -> complete_staged_registry_resources(runtime, registry, path) end) do
      {:ok, result} ->
        result

      {:error, reason} ->
        runtime.registry_module.close(registry)
        {{:error, {:registry_stage_failed, reason}}, false}
    end
  end

  defp complete_staged_registry_resources(runtime, registry, path) do
    staged_runtime = %{runtime | registry: registry}
    embedding_attempted? = Embeddings.reembed_after_reload?(staged_runtime, path)

    result =
      case Embeddings.reembed_after_reload(staged_runtime, path) do
        {:ok, next_runtime} ->
          :ok = runtime.registry_module.close(runtime.registry)
          {{:ok, next_runtime}, embedding_attempted?}

        {:error, _reason} = error ->
          :ok = runtime.registry_module.close(registry)
          {error, embedding_attempted?}
      end

    {:ok, result}
  end

  defp ensure_registry_owner(runtime) do
    case Registry.mutation_owner(runtime.registry_module, runtime.registry) do
      :shared -> :ok
      owner when owner == self() -> :ok
      owner -> {:error, {:registry_not_owner, owner}}
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp emit_registry_event(
         event,
         start,
         _original_runtime,
         {:ok, %__MODULE__{} = runtime},
         metadata
       ) do
    Telemetry.execute(
      event,
      %{
        duration: System.monotonic_time() - start,
        action_count: action_count(runtime)
      },
      Map.put(metadata, :result, :ok)
    )
  end

  defp emit_registry_event(event, start, original_runtime, {:error, reason}, metadata) do
    Telemetry.execute(
      event,
      %{
        duration: System.monotonic_time() - start,
        action_count: action_count(original_runtime)
      },
      metadata
      |> Map.put(:result, :error)
      |> Map.put(:reason, reason)
    )
  end

  defp emit_registry_event(_event, _start, _original_runtime, _result, _metadata), do: :ok

  defp emit_delete_event(
         start,
         _original_runtime,
         {:ok, deleted, %__MODULE__{} = runtime},
         action_id
       ) do
    Telemetry.execute(
      @registry_delete_event,
      %{
        duration: System.monotonic_time() - start,
        action_count: action_count(runtime)
      },
      %{result: :ok, action_id: action_id, deleted: deleted}
    )
  end

  defp emit_delete_event(start, original_runtime, {:error, reason}, action_id) do
    Telemetry.execute(
      @registry_delete_event,
      %{
        duration: System.monotonic_time() - start,
        action_count: action_count(original_runtime)
      },
      %{result: :error, action_id: action_id, reason: reason}
    )
  end

  defp registry_format(path) when is_binary(path) do
    cond do
      String.ends_with?(path, ".json") -> :json
      String.ends_with?(path, ".etf") -> :etf
      true -> :unknown
    end
  end

  defp registry_format(_path), do: :unknown

  defp action_id(%{"id" => id}) when is_binary(id), do: id
  defp action_id(%{id: id}) when is_binary(id), do: id
  defp action_id(_action), do: nil
end
