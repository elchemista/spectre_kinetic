defmodule SpectreKinetic.Reranker.Runtime.Axon do
  @moduledoc """
  Elixir-native reranker runtime for Axon-trained fallback artifacts.

  Expected files in `fallback_model_dir`:

    * `params.etf`
    * `metadata.json`

  The metadata file must include `encoder_model_dir`, `feature_dim`, and
  `hidden_dim`.
  """

  alias SpectreKinetic.Artifact
  alias SpectreKinetic.ONNX
  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Reranker.FeatureBuilder
  alias SpectreKinetic.Reranker.Trainer

  defstruct [:embedder, :embedding_module, :model, :model_state]

  @type t :: %__MODULE__{
          embedder: term(),
          embedding_module: module(),
          model: Axon.t(),
          model_state: term()
        }

  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts) do
    embedding_module = Keyword.get(opts, :embedding_module, EmbeddingRuntime)

    with {:ok, model_dir} <- fetch_model_dir(opts),
         {:ok, metadata} <-
           Artifact.read_json(
             Path.join(model_dir, "metadata.json"),
             artifact_opts(opts, :metadata_max_bytes)
           ),
         :ok <- validate_metadata(metadata),
         {:ok, model_state} <-
           Artifact.read_term(
             Path.join(model_dir, "params.etf"),
             artifact_opts(opts, :params_max_bytes)
           ),
         {:ok, embedder} <-
           embedding_module.load(
             encoder_model_dir:
               Keyword.get(opts, :encoder_model_dir, Map.fetch!(metadata, "encoder_model_dir"))
           ) do
      model =
        Trainer.build_model(
          Map.fetch!(metadata, "feature_dim"),
          Map.fetch!(metadata, "hidden_dim")
        )

      {:ok,
       %__MODULE__{
         embedder: embedder,
         embedding_module: embedding_module,
         model: model,
         model_state: model_state
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp fetch_model_dir(opts) do
    case Keyword.fetch(opts, :fallback_model_dir) do
      {:ok, model_dir} when is_binary(model_dir) -> {:ok, model_dir}
      {:ok, _invalid} -> {:error, {:invalid_option, :fallback_model_dir}}
      :error -> {:error, {:missing_option, :fallback_model_dir}}
    end
  end

  defp validate_metadata(metadata) when is_map(metadata) do
    required = ["encoder_model_dir", "feature_dim", "hidden_dim"]

    cond do
      Enum.any?(required, &(not Map.has_key?(metadata, &1))) ->
        {:error, {:invalid_metadata, :missing_fields}}

      not is_binary(metadata["encoder_model_dir"]) ->
        {:error, {:invalid_metadata, :encoder_model_dir}}

      not is_integer(metadata["feature_dim"]) or metadata["feature_dim"] <= 0 ->
        {:error, {:invalid_metadata, :feature_dim}}

      not is_integer(metadata["hidden_dim"]) or metadata["hidden_dim"] <= 0 ->
        {:error, {:invalid_metadata, :hidden_dim}}

      true ->
        :ok
    end
  end

  defp validate_metadata(_metadata), do: {:error, {:invalid_metadata, :root}}

  defp artifact_opts(opts, key) do
    case Keyword.get(opts, key, Keyword.get(opts, :artifact_max_bytes)) do
      nil -> []
      max_bytes -> [max_bytes: max_bytes]
    end
  end

  @spec score_batch(t(), [{binary(), binary()}]) :: {:ok, [float()]} | {:error, term()}
  def score_batch(%__MODULE__{} = runtime, pairs) do
    examples =
      Enum.map(pairs, fn {query, tool_card} ->
        %{query: query, tool_card: tool_card}
      end)

    case FeatureBuilder.build_matrix(
           runtime.embedder,
           examples,
           embedding_module: runtime.embedding_module
         ) do
      {:ok, features} ->
        scores =
          runtime.model
          |> Trainer.predict(runtime.model_state, features)
          |> Nx.to_flat_list()
          |> Enum.map(&ONNX.normalize_number/1)

        {:ok, scores}

      {:error, _reason} = error ->
        error
    end
  end
end
