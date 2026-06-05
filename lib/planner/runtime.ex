defmodule SpectreKinetic.Planner.Runtime do
  @moduledoc """
  Library-first planner runtime.

  This runtime is a small explicit struct that holds the loaded encoder, the
  selected registry backend module, the backend handle/state, and default
  planning thresholds.
  """

  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Runtime.Embeddings
  alias SpectreKinetic.Planner.Runtime.Loader

  defstruct [
    :registry_module,
    :registry,
    :encoder,
    :reranker_module,
    :reranker,
    :defaults,
    :classifiers,
    :chain_classifiers
  ]

  @type t :: %__MODULE__{
          registry_module: module(),
          registry: term(),
          encoder: EmbeddingRuntime.runtime_t() | nil,
          reranker_module: module(),
          reranker: term() | nil,
          defaults: keyword(),
          classifiers: [module() | {module(), keyword()}],
          chain_classifiers: [module() | {module(), keyword()}]
        }

  @doc """
  Loads a runtime from the provided options.

  Supported options:

    * `:registry_module` — registry backend module, defaults to ETS
    * `:registry_json` — registry JSON source path
    * `:compiled_registry` — compiled ETF bundle path
    * `:encoder_model_dir` — ONNX encoder directory
    * `:top_k`, `:tool_threshold`, `:mapping_threshold` — default planner opts
    * `:tool_selection_fallback` — `:disabled` or `:reranker`
    * `:fallback_model_dir` — path to reranker ONNX directory
    * `:fallback_top_k`, `:fallback_margin` — reranker fallback tuning
    * `:classifiers` — planning-time classifier pipeline specs
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    with {:ok, components} <- Loader.components(opts) do
      __MODULE__
      |> struct(components)
      |> Embeddings.embed_loaded_registry(opts)
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
  Reloads the runtime registry from either JSON or compiled ETF and returns the
  updated runtime.
  """
  @spec reload_registry(t(), binary()) :: {:ok, t()} | {:error, term()}
  def reload_registry(%__MODULE__{} = runtime, path) do
    with {:ok, registry} <-
           Loader.reload_registry(runtime.registry_module, runtime.registry, path) do
      runtime
      |> Map.put(:registry, registry)
      |> Embeddings.reembed_after_reload(path)
    end
  end

  @doc """
  Adds one action definition to the runtime registry and returns the updated runtime.
  """
  @spec add_action(t(), map()) :: {:ok, t()} | {:error, term()}
  def add_action(%__MODULE__{} = runtime, action) do
    with {:ok, registry} <- runtime.registry_module.add_action(runtime.registry, action),
         runtime <- %{runtime | registry: registry},
         {:ok, registry} <- Embeddings.maybe_embed_action(runtime, action) do
      {:ok, %{runtime | registry: registry}}
    end
  end

  @doc """
  Deletes one action definition from the runtime registry and returns the updated runtime.
  """
  @spec delete_action(t(), binary()) :: {:ok, boolean(), t()} | {:error, term()}
  def delete_action(%__MODULE__{} = runtime, action_id) do
    case runtime.registry_module.delete_action(runtime.registry, action_id) do
      {{:ok, deleted}, registry} ->
        {:ok, deleted, %{runtime | registry: registry}}

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
