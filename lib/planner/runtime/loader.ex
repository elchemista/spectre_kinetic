defmodule SpectreKinetic.Planner.Runtime.Loader do
  @moduledoc false

  alias SpectreKinetic.ClassifierPipeline
  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Registry.ETS
  alias SpectreKinetic.Reranker.Runtime, as: RerankerRuntime
  alias SpectreKinetic.RuntimeConfig
  alias SpectreKinetic.Telemetry

  @encoder_load_event [:spectre_kinetic, :runtime, :encoder, :load]
  @reranker_load_event [:spectre_kinetic, :runtime, :reranker, :load]

  @plan_default_keys [
    :top_k,
    :tool_threshold,
    :mapping_threshold,
    :tool_selection_fallback,
    :fallback_top_k,
    :fallback_margin,
    :reranker_threshold
  ]

  @reranker_runtime_options [
    {:reranker_max_length, :max_length},
    {:reranker_score_index, :score_index},
    {:reranker_score_transform, :score_transform}
  ]

  @registry_functions [
    new: 1,
    owner: 1,
    load_json: 2,
    load_compiled: 2,
    all_actions: 1,
    get_action: 2,
    action_count: 1,
    add_action: 2,
    upsert_action: 3,
    delete_action: 2,
    embedding_matrix: 1,
    put_embedding: 3,
    tool_cards: 1,
    resolve_alias: 2,
    close: 1
  ]

  @spec components(keyword()) :: {:ok, map()} | {:error, term()}
  def components(opts) do
    with :ok <- RuntimeConfig.validate_options(opts),
         :ok <- validate_registry_module(Keyword.get(opts, :registry_module, ETS)),
         :ok <- validate_reranker_module(opts),
         {:ok, paths} <- RuntimeConfig.resolve_runtime_paths(opts) do
      opts
      |> Keyword.merge(Map.to_list(paths))
      |> load_components()
    end
  end

  defp load_components(opts) do
    registry_module = Keyword.get(opts, :registry_module, ETS)
    reranker_module = Keyword.get(opts, :fallback_runtime_module, RerankerRuntime)
    defaults = planner_defaults(opts)

    with :ok <- RuntimeConfig.validate_options(defaults),
         {:ok, registry} <- load_registry(registry_module, opts) do
      load_owned_components(registry_module, registry, reranker_module, opts, defaults)
    end
  end

  defp load_owned_components(registry_module, registry, reranker_module, opts, defaults) do
    result =
      safely(fn ->
        with {:ok, encoder} <- load_encoder(opts),
             {:ok, reranker} <- load_reranker(opts, reranker_module),
             {:ok, classifiers} <- configured_classifiers(opts, :classifiers) do
          {:ok,
           %{
             registry_module: registry_module,
             registry: registry,
             encoder: encoder,
             reranker_module: reranker_module,
             reranker: reranker,
             allow_empty_registry: Keyword.get(opts, :allow_empty_registry, false),
             defaults: defaults,
             classifiers: classifiers
           }}
        end
      end)

    case result do
      {:ok, _components} = ok ->
        ok

      {:error, _reason} = error ->
        registry_module.close(registry)
        error
    end
  end

  defp load_registry(registry_module, opts) do
    with {:ok, registry} <- registry_module.new(opts) do
      if registry_module.action_count(registry) > 0 or
           Keyword.get(opts, :allow_empty_registry, false) do
        {:ok, registry}
      else
        registry_module.close(registry)
        {:error, :empty_registry}
      end
    end
  end

  @spec stage_registry(module(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def stage_registry(registry_module, path, opts \\ []) do
    with :ok <- RuntimeConfig.validate_options(opts),
         :ok <- validate_registry_module(registry_module),
         :ok <- RuntimeConfig.validate_path(path, :registry_path) do
      do_stage_registry(registry_module, path, opts)
    end
  end

  defp do_stage_registry(registry_module, path, opts) do
    case registry_loader(registry_module, path) do
      :unknown ->
        {:error, :unknown_registry_format}

      {:ok, loader} ->
        with {:ok, registry} <- registry_module.new([]) do
          case safely(fn -> loader.(registry, path) end) do
            {:ok, registry} -> validate_staged_registry(registry_module, registry, opts)
            {:error, _reason} = error -> close_staged(registry_module, registry, error)
          end
        end
    end
  end

  defp validate_registry_module(module) do
    with :ok <- RuntimeConfig.validate_module(module, :registry_module) do
      if Enum.all?(@registry_functions, fn {name, arity} ->
           function_exported?(module, name, arity)
         end) do
        :ok
      else
        invalid_module(:registry_module, :must_implement_registry_backend)
      end
    end
  end

  defp validate_reranker_module(opts) do
    module = Keyword.get(opts, :fallback_runtime_module, RerankerRuntime)

    with :ok <- RuntimeConfig.validate_module(module, :fallback_runtime_module) do
      required = required_reranker_functions(opts)

      if Enum.all?(required, fn {name, arity} -> function_exported?(module, name, arity) end) do
        :ok
      else
        invalid_module(:fallback_runtime_module, :must_implement_reranker_runtime)
      end
    end
  end

  defp required_reranker_functions(opts) do
    cond do
      not is_nil(Keyword.get(opts, :reranker)) -> [score_batch: 2]
      fallback_mode(opts) == :reranker -> [load: 1, score_batch: 2]
      true -> []
    end
  end

  defp invalid_module(field, reason),
    do: {:error, {:invalid_options, [%{field: field, reason: reason}]}}

  defp validate_staged_registry(registry_module, registry, opts) do
    if registry_module.action_count(registry) > 0 or
         Keyword.get(opts, :allow_empty_registry, false) do
      {:ok, registry}
    else
      close_staged(registry_module, registry, {:error, :empty_registry})
    end
  end

  defp close_staged(registry_module, registry, result) do
    registry_module.close(registry)
    result
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, {:runtime_component_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:runtime_component_failed, {kind, reason}}}
  end

  defp planner_defaults(opts) do
    RuntimeConfig.default_plan_options()
    |> Keyword.merge(Keyword.take(opts, @plan_default_keys))
  end

  defp configured_classifiers(opts, key) do
    specs =
      if Keyword.has_key?(opts, key) do
        Keyword.get(opts, key) || []
      else
        Application.get_env(:spectre_kinetic, key, [])
      end

    ClassifierPipeline.init_specs(specs)
  end

  defp load_encoder(opts) do
    case RuntimeConfig.resolve_optional_path(
           opts,
           :encoder_model_dir,
           :encoder_model_dir,
           "SPECTRE_KINETIC_ENCODER_MODEL_DIR"
         ) do
      nil ->
        Telemetry.execute(@encoder_load_event, %{duration: 0}, %{
          result: :skipped,
          reason: :missing_encoder_model_dir
        })

        {:ok, nil}

      encoder_model_dir ->
        timed_result(@encoder_load_event, %{path: encoder_model_dir}, fn ->
          EmbeddingRuntime.load(encoder_model_dir: encoder_model_dir)
        end)
    end
  end

  defp load_reranker(opts, reranker_module) do
    case {Keyword.get(opts, :reranker), fallback_mode(opts)} do
      {runtime, _mode} when not is_nil(runtime) ->
        Telemetry.execute(@reranker_load_event, %{duration: 0}, %{
          result: :ok,
          reason: :explicit_runtime,
          mode: :reranker
        })

        {:ok, runtime}

      {_runtime, mode} when mode != :reranker ->
        Telemetry.execute(@reranker_load_event, %{duration: 0}, %{
          result: :skipped,
          reason: :fallback_disabled,
          mode: mode
        })

        {:ok, nil}

      {_runtime, :reranker} ->
        load_optional_reranker(opts, reranker_module)
    end
  end

  defp fallback_mode(opts) do
    Keyword.get(opts, :tool_selection_fallback) ||
      Keyword.get(RuntimeConfig.default_plan_options(), :tool_selection_fallback, :disabled)
  end

  defp load_optional_reranker(opts, reranker_module) do
    case RuntimeConfig.resolve_optional_path(
           opts,
           :fallback_model_dir,
           :fallback_model_dir,
           "SPECTRE_KINETIC_FALLBACK_MODEL_DIR"
         ) do
      nil ->
        Telemetry.execute(@reranker_load_event, %{duration: 0}, %{
          result: :skipped,
          reason: :missing_fallback_model_dir,
          mode: :reranker
        })

        {:ok, nil}

      fallback_model_dir ->
        timed_result(
          @reranker_load_event,
          %{path: fallback_model_dir, mode: :reranker},
          fn -> reranker_module.load(reranker_load_opts(opts, fallback_model_dir)) end
        )
    end
  end

  defp reranker_load_opts(opts, fallback_model_dir) do
    Enum.reduce(
      @reranker_runtime_options,
      [fallback_model_dir: fallback_model_dir],
      fn {source_key, target_key}, runtime_opts ->
        case Keyword.get(opts, source_key, Application.get_env(:spectre_kinetic, source_key)) do
          nil -> runtime_opts
          value -> Keyword.put(runtime_opts, target_key, value)
        end
      end
    )
  end

  defp timed_result(event, metadata, fun) do
    start = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start

    case result do
      {:ok, _value} ->
        Telemetry.execute(event, %{duration: duration}, Map.put(metadata, :result, :ok))

      {:error, reason} ->
        metadata =
          metadata
          |> Map.put(:result, :error)
          |> Map.put(:reason, reason)

        Telemetry.execute(event, %{duration: duration}, metadata)

      _other ->
        Telemetry.execute(event, %{duration: duration}, Map.put(metadata, :result, :ok))
    end

    result
  end

  defp registry_loader(registry_module, path) when is_binary(path) do
    cond do
      String.ends_with?(path, ".json") -> {:ok, &registry_module.load_json/2}
      String.ends_with?(path, ".etf") -> {:ok, &registry_module.load_compiled/2}
      true -> :unknown
    end
  end

  defp registry_loader(_registry_module, _path), do: :unknown
end
