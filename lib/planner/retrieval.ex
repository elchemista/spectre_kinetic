defmodule SpectreKinetic.Planner.Retrieval do
  @moduledoc """
  Retrieves a bounded set of planner candidates.

  A complete embedding matrix enables vector retrieval. When the registry has
  no complete matrix, or the query embedder is unavailable, retrieval falls
  back to lexical scoring and emits the same telemetry event with a reason that
  identifies the unavailable vector component.
  """

  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Planner.RegistryStore
  alias SpectreKinetic.Planner.Scorer
  alias SpectreKinetic.RuntimeConfig
  alias SpectreKinetic.Telemetry

  @retrieval_fallback_event [:spectre_kinetic, :planner, :retrieval, :fallback]

  @type opts :: %{
          registry_module: module(),
          registry: term(),
          embedder: GenServer.server() | nil,
          top_k: pos_integer()
        }

  @type candidate :: %{action: map(), embedding_score: number()}

  @doc "Builds normalized retrieval options from planner options."
  @spec options(map()) :: opts()
  def options(opts) do
    %{
      registry_module: Map.get(opts, :registry_module, RegistryStore),
      registry: Map.get(opts, :registry, RegistryStore),
      embedder: Map.get(opts, :embedder),
      top_k: plan_option(opts, :top_k)
    }
  end

  @doc "Retrieves vector-ranked candidates, falling back to lexical ranking when necessary."
  @spec retrieve(binary(), opts()) :: {:ok, [candidate()]} | {:error, term()}
  def retrieve(al_text, %{
        registry_module: registry_module,
        registry: registry,
        embedder: embedder,
        top_k: top_k
      }) do
    case registry_read(:embedding_matrix, fn -> registry_module.embedding_matrix(registry) end) do
      {:ok, {matrix, action_ids}} ->
        retrieve_embedded(al_text, registry_module, registry, embedder, top_k, matrix, action_ids)

      {:ok, nil} ->
        result = retrieve_lexical(al_text, registry_module, registry, top_k)
        emit_lexical_fallback(result, top_k, :embedding_matrix_unavailable)
        result

      {:ok, other} ->
        {:error, {:invalid_registry_return, :embedding_matrix, other}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec retrieve_lexical(binary(), module(), term(), pos_integer()) ::
          {:ok, [candidate()]} | {:error, term()}
  defp retrieve_lexical(al_text, registry_module, registry, top_k) do
    with {:ok, actions} <-
           registry_read(:all_actions, fn -> registry_module.all_actions(registry) end),
         :ok <- validate_registry_actions(actions) do
      candidates =
        actions
        |> Enum.map(&lexical_candidate(al_text, &1))
        |> Enum.sort_by(& &1.embedding_score, :desc)
        |> Enum.take(top_k)

      {:ok, candidates}
    end
  end

  @spec lexical_candidate(binary(), map()) :: candidate()
  defp lexical_candidate(al_text, action) do
    card = Registry.build_tool_card(action)
    %{action: action, embedding_score: Scorer.lexical_overlap(al_text, card)}
  end

  @spec retrieve_embedded(
          binary(),
          module(),
          term(),
          GenServer.server() | nil,
          pos_integer(),
          Nx.Tensor.t(),
          [binary()]
        ) :: {:ok, [candidate()]} | {:error, term()}
  defp retrieve_embedded(al_text, registry_module, registry, embedder, top_k, matrix, action_ids) do
    case embed_query(embedder, al_text) do
      {:ok, query_vec} ->
        with :ok <- validate_embedding_inputs(query_vec, matrix, action_ids) do
          embedded_candidates(query_vec, matrix, top_k, action_ids, registry_module, registry)
        end

      {:error, :embedder_unavailable} ->
        result = retrieve_lexical(al_text, registry_module, registry, top_k)
        emit_lexical_fallback(result, top_k, :embedder_unavailable)
        result

      {:error, _reason} = error ->
        error
    end
  end

  @spec embedded_candidates(
          Nx.Tensor.t(),
          Nx.Tensor.t(),
          pos_integer(),
          [binary()],
          module(),
          term()
        ) :: {:ok, [candidate()]} | {:error, term()}
  defp embedded_candidates(query_vec, matrix, top_k, action_ids, registry_module, registry) do
    action_ids = List.to_tuple(action_ids)

    candidates =
      query_vec
      |> Scorer.cosine_similarity(matrix)
      |> Scorer.top_k(top_k)

    candidates
    |> Enum.reduce_while({:ok, []}, fn {idx, score}, {:ok, acc} ->
      action_id = elem(action_ids, idx)

      result =
        registry_read(:get_action, fn -> registry_module.get_action(registry, action_id) end)

      case result do
        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, action} when is_map(action) ->
          {:cont, {:ok, [%{action: action, embedding_score: score} | acc]}}

        {:ok, other} ->
          {:halt, {:error, {:invalid_registry_return, :get_action, other}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> reverse_candidates()
  end

  @spec reverse_candidates({:ok, [candidate()]} | {:error, term()}) ::
          {:ok, [candidate()]} | {:error, term()}
  defp reverse_candidates({:ok, candidates}), do: {:ok, Enum.reverse(candidates)}
  defp reverse_candidates({:error, _reason} = error), do: error

  @spec validate_embedding_inputs(Nx.Tensor.t(), term(), term()) :: :ok | {:error, term()}
  defp validate_embedding_inputs(%Nx.Tensor{} = query, %Nx.Tensor{} = matrix, action_ids)
       when is_list(action_ids) do
    with {:ok, query_dim} <- query_dimension(query),
         {:ok, row_count, matrix_dim} <- matrix_dimensions(matrix),
         :ok <- validate_action_ids(action_ids, row_count) do
      validate_embedding_dimensions(query_dim, matrix_dim)
    end
  end

  defp validate_embedding_inputs(%Nx.Tensor{}, _matrix, _action_ids),
    do: {:error, :invalid_embedding_matrix}

  @spec query_dimension(Nx.Tensor.t()) :: {:ok, pos_integer()} | {:error, term()}
  defp query_dimension(query) do
    case Nx.shape(query) do
      {dimension} when dimension > 0 -> {:ok, dimension}
      {1, dimension} when dimension > 0 -> {:ok, dimension}
      shape -> {:error, {:invalid_query_embedding_shape, shape}}
    end
  end

  @spec matrix_dimensions(Nx.Tensor.t()) ::
          {:ok, pos_integer(), pos_integer()} | {:error, term()}
  defp matrix_dimensions(matrix) do
    case Nx.shape(matrix) do
      {rows, dimension} when rows > 0 and dimension > 0 -> {:ok, rows, dimension}
      shape -> {:error, {:invalid_embedding_matrix_shape, shape}}
    end
  end

  @spec validate_action_ids(term(), pos_integer()) :: :ok | {:error, term()}
  defp validate_action_ids(action_ids, row_count) do
    cond do
      length(action_ids) != row_count ->
        {:error, {:embedding_action_count_mismatch, row_count, length(action_ids)}}

      Enum.any?(action_ids, &(not is_binary(&1))) ->
        {:error, :invalid_embedding_action_ids}

      true ->
        :ok
    end
  end

  @spec validate_embedding_dimensions(pos_integer(), pos_integer()) ::
          :ok | {:error, term()}
  defp validate_embedding_dimensions(dimension, dimension), do: :ok

  defp validate_embedding_dimensions(query_dimension, matrix_dimension) do
    {:error, {:embedding_dimension_mismatch, query_dimension, matrix_dimension}}
  end

  @spec embed_query(GenServer.server() | nil, binary()) ::
          {:ok, Nx.Tensor.t()} | {:error, term()}
  defp embed_query(nil, _al_text), do: {:error, :embedder_unavailable}
  defp embed_query(embedder, al_text), do: EmbeddingRuntime.embed(embedder, al_text)

  @spec emit_lexical_fallback({:ok, [candidate()]} | {:error, term()}, pos_integer(), atom()) ::
          :ok
  defp emit_lexical_fallback({:ok, candidates}, top_k, reason) do
    Telemetry.execute(
      @retrieval_fallback_event,
      %{candidate_count: length(candidates), fallback_top_k: top_k},
      %{result: :fallback, reason: reason}
    )
  end

  defp emit_lexical_fallback({:error, _reason}, _top_k, _fallback_reason), do: :ok

  @spec validate_registry_actions(term()) :: :ok | {:error, term()}
  defp validate_registry_actions(actions) when is_list(actions) do
    if Enum.all?(actions, &is_map/1),
      do: :ok,
      else: {:error, {:invalid_registry_return, :all_actions, actions}}
  end

  defp validate_registry_actions(other),
    do: {:error, {:invalid_registry_return, :all_actions, other}}

  @spec registry_read(atom(), (-> term())) :: {:ok, term()} | {:error, term()}
  defp registry_read(operation, callback) do
    case callback.() do
      {:error, _reason} = error -> error
      value -> {:ok, value}
    end
  rescue
    error ->
      {:error,
       {:registry_backend_failed, operation, {:raise, error.__struct__, Exception.message(error)}}}
  catch
    kind, reason -> {:error, {:registry_backend_failed, operation, {kind, reason}}}
  end

  @spec plan_option(map(), atom()) :: term()
  defp plan_option(opts, key) do
    Map.get(opts, key, Keyword.fetch!(RuntimeConfig.built_in_plan_defaults(), key))
  end
end
