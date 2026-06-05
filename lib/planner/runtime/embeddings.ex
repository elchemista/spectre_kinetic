defmodule SpectreKinetic.Planner.Runtime.Embeddings do
  @moduledoc false

  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.RuntimeConfig

  @spec embed_loaded_registry(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def embed_loaded_registry(runtime, opts) do
    if should_embed_loaded_registry?(runtime, opts),
      do: reembed_all(runtime),
      else: {:ok, runtime}
  end

  @spec reembed_after_reload(map(), binary()) :: {:ok, map()} | {:error, term()}
  def reembed_after_reload(runtime, path) do
    if should_reembed_after_reload?(runtime, path),
      do: reembed_all(runtime),
      else: {:ok, runtime}
  end

  @spec maybe_embed_action(map(), map()) :: {:ok, term()} | {:error, term()}
  def maybe_embed_action(%{encoder: nil, registry: registry}, _action), do: {:ok, registry}

  def maybe_embed_action(runtime, action) do
    action = normalize_or_keep(action)

    with id when is_binary(id) <- action["id"],
         stored when is_map(stored) <- runtime.registry_module.get_action(runtime.registry, id),
         {:ok, vector} <-
           EmbeddingRuntime.embed(runtime.encoder, Registry.build_tool_card(stored)),
         {:ok, registry} <-
           runtime.registry_module.put_embedding(
             runtime.registry,
             id,
             Nx.backend_transfer(vector)
           ) do
      {:ok, registry}
    else
      false -> {:ok, runtime.registry}
      nil -> {:ok, runtime.registry}
      {:error, _reason} = error -> error
    end
  end

  # Compiled registries may already carry embeddings. JSON is raw ingredients,
  # so when an encoder exists we cook the boring matrix now and spare callers.
  defp should_embed_loaded_registry?(%{encoder: nil}, _opts), do: false

  defp should_embed_loaded_registry?(runtime, opts) do
    paths = registry_source_paths(opts)

    (paths.registry_json && is_nil(paths.compiled_registry)) || missing_embeddings?(runtime)
  end

  defp should_reembed_after_reload?(%{encoder: nil}, _path), do: false

  defp should_reembed_after_reload?(runtime, path) when is_binary(path) do
    String.ends_with?(path, ".json") || missing_embeddings?(runtime)
  end

  defp registry_source_paths(opts) do
    %{
      registry_json:
        RuntimeConfig.resolve_optional_path(
          opts,
          :registry_json,
          :registry_json,
          "SPECTRE_KINETIC_REGISTRY_JSON"
        ),
      compiled_registry:
        RuntimeConfig.resolve_optional_path(
          opts,
          :compiled_registry,
          :compiled_registry,
          "SPECTRE_KINETIC_COMPILED_REGISTRY"
        )
    }
  end

  defp missing_embeddings?(runtime) do
    is_nil(runtime.registry_module.embedding_matrix(runtime.registry))
  end

  defp reembed_all(runtime) do
    case runtime.registry_module.tool_cards(runtime.registry) do
      [] ->
        {:ok, runtime}

      cards ->
        put_card_embeddings(runtime, cards)
    end
  end

  defp put_card_embeddings(runtime, cards) do
    {action_ids, texts} = Enum.unzip(cards)

    with {:ok, matrix} <- EmbeddingRuntime.embed_batch(runtime.encoder, texts),
         {:ok, registry} <-
           put_embedding_rows(runtime.registry_module, runtime.registry, action_ids, matrix) do
      {:ok, %{runtime | registry: registry}}
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

  defp normalize_or_keep(action) do
    case Registry.normalize_action(action) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> action
    end
  end
end
