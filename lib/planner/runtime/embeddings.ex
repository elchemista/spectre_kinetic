defmodule SpectreKinetic.Planner.Runtime.Embeddings do
  @moduledoc """
  Maintains the embedding side of a planner runtime registry.

  Registry mutation and model inference are kept separate: this module asks
  the configured encoder for vectors, validates their shape, type, size, and
  numeric values, and only then writes them through the registry behaviour.
  Failed validation leaves the caller's runtime unchanged.

  Compiled registries may already contain complete embeddings. JSON registries
  contain only action definitions, so they are embedded when an encoder is
  available. Reloads follow the same rule and rebuild vectors only when the
  loaded generation does not provide complete coverage.
  """

  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.RuntimeConfig
  alias SpectreKinetic.Telemetry

  @embed_event [:spectre_kinetic, :runtime, :registry, :embed]
  @max_embedding_dim 16_384
  @max_embedding_cells 4_194_304

  @doc """
  Embeds a newly loaded registry when its source or coverage requires it.

  Returns the original runtime unchanged when no encoder is configured or the
  registry already contains a complete embedding matrix.
  """
  @spec embed_loaded_registry(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def embed_loaded_registry(runtime, opts) do
    if should_embed_loaded_registry?(runtime, opts) do
      reembed_all(runtime, %{scope: :loaded_registry})
    else
      emit_embed_skipped(runtime, %{
        scope: :loaded_registry,
        reason: loaded_registry_skip_reason(runtime)
      })

      {:ok, runtime}
    end
  end

  @doc """
  Rebuilds embeddings after a registry reload when the new generation needs it.
  """
  @spec reembed_after_reload(map(), binary()) :: {:ok, map()} | {:error, term()}
  def reembed_after_reload(runtime, path) do
    if reembed_after_reload?(runtime, path) do
      reembed_all(runtime, %{scope: :reload, path: path, format: registry_format(path)})
    else
      emit_embed_skipped(runtime, %{
        scope: :reload,
        path: path,
        format: registry_format(path),
        reason: reload_skip_reason(runtime)
      })

      {:ok, runtime}
    end
  end

  @doc """
  Returns whether a registry reload requires embeddings to be rebuilt.
  """
  @spec reembed_after_reload?(map(), binary()) :: boolean()
  def reembed_after_reload?(runtime, path), do: should_reembed_after_reload?(runtime, path)

  @doc """
  Normalizes an action and prepares its optional embedding before insertion.

  The registry is not mutated here. Callers receive the normalized action and
  vector so they can perform one validated upsert at the registry boundary.
  """
  @spec prepare_action(map(), map()) ::
          {:ok, Registry.action(), Nx.Tensor.t() | nil} | {:error, term()}
  def prepare_action(runtime, action) do
    with {:ok, action} <- Registry.normalize_action(action) do
      prepare_action_embedding(runtime, action)
    end
  end

  @spec should_embed_loaded_registry?(map(), keyword()) :: boolean()
  defp should_embed_loaded_registry?(%{encoder: nil}, _opts), do: false

  defp should_embed_loaded_registry?(runtime, opts) do
    paths = registry_source_paths(opts)

    (paths.registry_json && is_nil(paths.compiled_registry)) || missing_embeddings?(runtime)
  end

  @spec should_reembed_after_reload?(map(), binary()) :: boolean()
  defp should_reembed_after_reload?(%{encoder: nil}, _path), do: false

  defp should_reembed_after_reload?(runtime, path) when is_binary(path) do
    String.ends_with?(path, ".json") || missing_embeddings?(runtime)
  end

  @spec registry_source_paths(keyword()) :: %{
          registry_json: binary() | nil,
          compiled_registry: binary() | nil
        }
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

  @spec missing_embeddings?(map()) :: boolean()
  defp missing_embeddings?(runtime) do
    is_nil(runtime.registry_module.embedding_matrix(runtime.registry))
  end

  @spec reembed_all(map(), map()) :: {:ok, map()} | {:error, term()}
  defp reembed_all(runtime, metadata) do
    start = System.monotonic_time()

    case runtime.registry_module.tool_cards(runtime.registry) do
      [] ->
        emit_embed(
          @embed_event,
          start,
          runtime,
          Map.merge(metadata, %{result: :skipped, reason: :empty_registry})
        )

        {:ok, runtime}

      cards ->
        case put_card_embeddings(runtime, cards) do
          {:ok, runtime} = ok ->
            emit_embed(
              @embed_event,
              start,
              runtime,
              Map.merge(metadata, %{result: :ok, embedded_count: length(cards)})
            )

            ok

          {:error, reason} = error ->
            emit_embed(
              @embed_event,
              start,
              runtime,
              Map.merge(metadata, %{result: :error, reason: reason})
            )

            error
        end
    end
  end

  @spec put_card_embeddings(map(), [{binary(), binary()}]) ::
          {:ok, map()} | {:error, term()}
  defp put_card_embeddings(runtime, cards) do
    {action_ids, texts} = Enum.unzip(cards)

    with {:ok, matrix} <- EmbeddingRuntime.embed_batch(runtime.encoder, texts),
         :ok <- validate_embedding_batch(matrix, length(action_ids)),
         {:ok, registry} <-
           put_embedding_rows(runtime.registry_module, runtime.registry, action_ids, matrix) do
      {:ok, %{runtime | registry: registry}}
    end
  end

  @spec put_embedding_rows(module(), term(), [binary()], Nx.Tensor.t()) ::
          {:ok, term()} | {:error, term()}
  defp put_embedding_rows(registry_module, registry, action_ids, matrix) do
    Enum.reduce_while(Enum.with_index(action_ids), {:ok, registry}, fn {action_id, index},
                                                                       {:ok, acc} ->
      case registry_module.put_embedding(acc, action_id, Nx.backend_transfer(matrix[index])) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec validate_embedding_batch(Nx.Tensor.t(), non_neg_integer()) ::
          :ok
          | {:error, :invalid_embedding_batch | :non_finite_embedding_batch}
          | {:error, {:invalid_embedding_batch_shape, tuple(), non_neg_integer()}}
          | {:error, {:invalid_embedding_batch_type, term()}}
  defp validate_embedding_batch(%Nx.Tensor{} = matrix, expected_rows) do
    case Nx.shape(matrix) do
      {^expected_rows, dimension}
      when dimension > 0 and dimension <= @max_embedding_dim and
             expected_rows * dimension <= @max_embedding_cells ->
        with :ok <- validate_embedding_batch_type(matrix) do
          validate_embedding_batch_values(matrix)
        end

      shape ->
        {:error, {:invalid_embedding_batch_shape, shape, expected_rows}}
    end
  end

  @spec validate_embedding_batch_type(Nx.Tensor.t()) ::
          :ok | {:error, {:invalid_embedding_batch_type, term()}}
  defp validate_embedding_batch_type(matrix) do
    case Nx.type(matrix) do
      {:f, _bits} -> :ok
      {:bf, _bits} -> :ok
      type -> {:error, {:invalid_embedding_batch_type, type}}
    end
  end

  @spec validate_embedding_batch_values(Nx.Tensor.t()) ::
          :ok | {:error, :invalid_embedding_batch | :non_finite_embedding_batch}
  defp validate_embedding_batch_values(matrix) do
    if matrix |> Nx.to_flat_list() |> Enum.all?(&finite_number?/1),
      do: :ok,
      else: {:error, :non_finite_embedding_batch}
  rescue
    _error -> {:error, :invalid_embedding_batch}
  end

  @spec finite_number?(term()) :: boolean()
  defp finite_number?(value) when is_integer(value), do: true

  defp finite_number?(value) when is_float(value) do
    representation = value |> :erlang.float_to_binary([:compact]) |> String.downcase()
    representation not in ["nan", "inf", "-inf"]
  rescue
    _error -> false
  end

  defp finite_number?(_value), do: false

  @spec prepare_action_embedding(map(), Registry.action()) ::
          {:ok, Registry.action(), Nx.Tensor.t() | nil} | {:error, term()}
  defp prepare_action_embedding(%{encoder: nil} = runtime, action) do
    emit_embed_skipped(runtime, %{
      scope: :action,
      action_id: action["id"],
      reason: :no_encoder
    })

    {:ok, action, nil}
  end

  defp prepare_action_embedding(runtime, action) do
    start = System.monotonic_time()

    case EmbeddingRuntime.embed(runtime.encoder, Registry.build_tool_card(action)) do
      {:ok, vector} ->
        emit_embed(@embed_event, start, runtime, %{
          scope: :action,
          action_id: action["id"],
          result: :ok
        })

        {:ok, action, Nx.backend_transfer(vector)}

      {:error, reason} = error ->
        emit_embed(@embed_event, start, runtime, %{
          scope: :action,
          action_id: action["id"],
          result: :error,
          reason: reason
        })

        error
    end
  end

  @spec emit_embed_skipped(map(), map()) :: :ok
  defp emit_embed_skipped(runtime, metadata) do
    Telemetry.execute(
      @embed_event,
      %{duration: 0, action_count: action_count(runtime)},
      Map.put(metadata, :result, :skipped)
    )
  end

  @spec emit_embed([atom()], integer(), map(), map()) :: :ok
  defp emit_embed(event, start, runtime, metadata) do
    Telemetry.execute(
      event,
      %{
        duration: System.monotonic_time() - start,
        action_count: action_count(runtime)
      },
      metadata
    )
  end

  @spec loaded_registry_skip_reason(map()) :: :no_encoder | :embeddings_present
  defp loaded_registry_skip_reason(%{encoder: nil}), do: :no_encoder
  defp loaded_registry_skip_reason(_runtime), do: :embeddings_present

  @spec reload_skip_reason(map()) :: :no_encoder | :embeddings_present
  defp reload_skip_reason(%{encoder: nil}), do: :no_encoder
  defp reload_skip_reason(_runtime), do: :embeddings_present

  @spec registry_format(binary()) :: :json | :etf | :unknown
  defp registry_format(path) when is_binary(path) do
    cond do
      String.ends_with?(path, ".json") -> :json
      String.ends_with?(path, ".etf") -> :etf
      true -> :unknown
    end
  end

  @spec action_count(map()) :: non_neg_integer()
  defp action_count(runtime), do: runtime.registry_module.action_count(runtime.registry)
end
