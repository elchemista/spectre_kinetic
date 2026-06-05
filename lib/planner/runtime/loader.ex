defmodule SpectreKinetic.Planner.Runtime.Loader do
  @moduledoc false

  alias SpectreKinetic.ClassifierPipeline
  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Registry.ETS
  alias SpectreKinetic.Reranker.Runtime, as: RerankerRuntime
  alias SpectreKinetic.RuntimeConfig

  @plan_default_keys [
    :top_k,
    :tool_threshold,
    :mapping_threshold,
    :tool_selection_fallback,
    :fallback_top_k,
    :fallback_margin
  ]

  @spec components(keyword()) :: {:ok, map()} | {:error, term()}
  def components(opts) do
    registry_module = Keyword.get(opts, :registry_module, ETS)
    reranker_module = Keyword.get(opts, :fallback_runtime_module, RerankerRuntime)

    with {:ok, registry} <- registry_module.new(opts),
         {:ok, encoder} <- load_encoder(opts),
         {:ok, reranker} <- load_reranker(opts, reranker_module),
         {:ok, classifiers} <- configured_classifiers(opts, :classifiers),
         {:ok, chain_classifiers} <- configured_classifiers(opts, :chain_classifiers) do
      {:ok,
       %{
         registry_module: registry_module,
         registry: registry,
         encoder: encoder,
         reranker_module: reranker_module,
         reranker: reranker,
         defaults: planner_defaults(opts),
         classifiers: classifiers,
         chain_classifiers: chain_classifiers
       }}
    end
  end

  @spec reload_registry(module(), term(), binary()) :: {:ok, term()} | {:error, term()}
  def reload_registry(registry_module, registry, path) do
    case registry_loader(registry_module, path) do
      :unknown ->
        {:error, :unknown_registry_format}

      {:ok, loader} ->
        loader.(registry, path)
    end
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
      nil -> {:ok, nil}
      encoder_model_dir -> EmbeddingRuntime.load(encoder_model_dir: encoder_model_dir)
    end
  end

  defp load_reranker(opts, reranker_module) do
    case {Keyword.get(opts, :reranker), fallback_mode(opts)} do
      {runtime, _mode} when not is_nil(runtime) ->
        {:ok, runtime}

      {_runtime, mode} when mode != :reranker ->
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
      nil -> {:ok, nil}
      fallback_model_dir -> reranker_module.load(fallback_model_dir: fallback_model_dir)
    end
  end

  defp registry_loader(registry_module, path) do
    cond do
      String.ends_with?(path, ".json") -> {:ok, &registry_module.load_json/2}
      String.ends_with?(path, ".etf") -> {:ok, &registry_module.load_compiled/2}
      true -> :unknown
    end
  end
end
