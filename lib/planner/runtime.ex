defmodule SpectreKinetic.Planner.Runtime do
  @moduledoc """
  Library-first planner runtime.

  This runtime is a small explicit struct that holds the loaded encoder, the
  selected registry backend module, the backend handle/state, and default
  planning thresholds.
  """

  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Planner.Registry.ETS
  alias SpectreKinetic.Planner.RerankerRuntime
  alias SpectreKinetic.Runtime, as: ConfigRuntime

  defstruct [
    :registry_module,
    :registry,
    :encoder,
    :reranker_module,
    :reranker,
    :defaults
  ]

  @type t :: %__MODULE__{
          registry_module: module(),
          registry: term(),
          encoder: EmbeddingRuntime.runtime_t() | nil,
          reranker_module: module(),
          reranker: term() | nil,
          defaults: keyword()
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
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    registry_module = Keyword.get(opts, :registry_module, ETS)
    reranker_module = Keyword.get(opts, :fallback_runtime_module, RerankerRuntime)

    with {:ok, registry} <- registry_module.new(opts),
         {:ok, encoder} <- maybe_load_encoder(opts),
         {:ok, reranker} <- maybe_load_reranker(opts, reranker_module) do
      runtime = %__MODULE__{
        registry_module: registry_module,
        registry: registry,
        encoder: encoder,
        reranker_module: reranker_module,
        reranker: reranker,
        defaults: planner_defaults(opts)
      }

      maybe_embed_registry(runtime, opts)
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
    registry_module = runtime.registry_module

    loader =
      cond do
        String.ends_with?(path, ".json") -> &registry_module.load_json/2
        String.ends_with?(path, ".etf") -> &registry_module.load_compiled/2
        true -> nil
      end

    case loader do
      nil ->
        {:error, :unknown_registry_format}

      loader ->
        with {:ok, registry} <- loader.(runtime.registry, path),
             {:ok, runtime} <- maybe_reembed(%{runtime | registry: registry}, path) do
          {:ok, runtime}
        end
    end
  end

  @doc """
  Adds one action definition to the runtime registry and returns the updated runtime.
  """
  @spec add_action(t(), map()) :: {:ok, t()} | {:error, term()}
  def add_action(%__MODULE__{} = runtime, action) do
    with {:ok, registry} <- runtime.registry_module.add_action(runtime.registry, action),
         {:ok, registry} <-
           maybe_embed_action(runtime.encoder, runtime.registry_module, registry, action) do
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

  defp planner_defaults(opts) do
    ConfigRuntime.default_plan_options()
    |> Keyword.merge(
      opts
      |> Keyword.take([
        :top_k,
        :tool_threshold,
        :mapping_threshold,
        :tool_selection_fallback,
        :fallback_top_k,
        :fallback_margin
      ])
    )
  end

  defp maybe_load_encoder(opts) do
    case ConfigRuntime.resolve_optional_path(
           opts,
           :encoder_model_dir,
           :encoder_model_dir,
           "SPECTRE_KINETIC_ENCODER_MODEL_DIR"
         ) do
      nil -> {:ok, nil}
      encoder_model_dir -> EmbeddingRuntime.load(encoder_model_dir: encoder_model_dir)
    end
  end

  defp maybe_load_reranker(opts, reranker_module) do
    fallback_mode =
      Keyword.get(opts, :tool_selection_fallback) ||
        Keyword.get(ConfigRuntime.default_plan_options(), :tool_selection_fallback, :disabled)

    cond do
      runtime = Keyword.get(opts, :reranker) ->
        {:ok, runtime}

      fallback_mode != :reranker ->
        {:ok, nil}

      true ->
        case ConfigRuntime.resolve_optional_path(
               opts,
               :fallback_model_dir,
               :fallback_model_dir,
               "SPECTRE_KINETIC_FALLBACK_MODEL_DIR"
             ) do
          nil -> {:ok, nil}
          fallback_model_dir -> reranker_module.load(fallback_model_dir: fallback_model_dir)
        end
    end
  end

  defp maybe_embed_registry(runtime, opts) do
    source =
      ConfigRuntime.resolve_optional_path(
        opts,
        :registry_json,
        :registry_json,
        "SPECTRE_KINETIC_REGISTRY_JSON"
      )

    compiled =
      ConfigRuntime.resolve_optional_path(
        opts,
        :compiled_registry,
        :compiled_registry,
        "SPECTRE_KINETIC_COMPILED_REGISTRY"
      )

    cond do
      is_nil(runtime.encoder) ->
        {:ok, runtime}

      source && is_nil(compiled) ->
        reembed_all(runtime)

      is_nil(runtime.registry_module.embedding_matrix(runtime.registry)) ->
        reembed_all(runtime)

      true ->
        {:ok, runtime}
    end
  end

  defp maybe_reembed(runtime, path) do
    cond do
      is_nil(runtime.encoder) ->
        {:ok, runtime}

      String.ends_with?(path, ".json") ->
        reembed_all(runtime)

      is_nil(runtime.registry_module.embedding_matrix(runtime.registry)) ->
        reembed_all(runtime)

      true ->
        {:ok, runtime}
    end
  end

  defp reembed_all(%__MODULE__{} = runtime) do
    cards = runtime.registry_module.tool_cards(runtime.registry)

    case cards do
      [] ->
        {:ok, runtime}

      _ ->
        {action_ids, texts} = Enum.unzip(cards)

        with {:ok, matrix} <- EmbeddingRuntime.embed_batch(runtime.encoder, texts),
             {:ok, registry} <-
               put_embedding_rows(runtime.registry_module, runtime.registry, action_ids, matrix) do
          {:ok, %{runtime | registry: registry}}
        end
    end
  end

  defp put_embedding_rows(registry_module, registry, action_ids, matrix) do
    Enum.reduce_while(Enum.with_index(action_ids), {:ok, registry}, fn {action_id, index},
                                                                       {:ok, acc} ->
      case registry_module.put_embedding(acc, action_id, Nx.backend_transfer(matrix[index])) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp maybe_embed_action(nil, _registry_module, registry, _action), do: {:ok, registry}

  defp maybe_embed_action(encoder, registry_module, registry, action) do
    action =
      case Registry.normalize_action(action) do
        {:ok, normalized} -> normalized
        {:error, _reason} -> action
      end

    with id when is_binary(id) <- action["id"],
         stored when is_map(stored) <- registry_module.get_action(registry, id),
         {:ok, vector} <- EmbeddingRuntime.embed(encoder, Registry.build_tool_card(stored)),
         {:ok, registry} <-
           registry_module.put_embedding(registry, id, Nx.backend_transfer(vector)) do
      {:ok, registry}
    else
      false -> {:ok, registry}
      nil -> {:ok, registry}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
