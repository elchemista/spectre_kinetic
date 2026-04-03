defmodule SpectreKinetic.Planner.RerankerRuntime.Axon do
  @moduledoc """
  Elixir-native reranker runtime for Axon-trained fallback artifacts.

  Expected files in `fallback_model_dir`:

    * `params.etf`
    * `metadata.json`

  The metadata file must include `encoder_model_dir`, `feature_dim`, and
  `hidden_dim`.
  """

  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Training.FeatureBuilder
  alias SpectreKinetic.Training.Reranker, as: RerankerTrainer

  defstruct [:embedder, :model, :model_state]

  @type t :: %__MODULE__{
          embedder: EmbeddingRuntime.runtime_t(),
          model: Axon.t(),
          model_state: term()
        }

  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts) do
    model_dir = Keyword.fetch!(opts, :fallback_model_dir)
    metadata_path = Path.join(model_dir, "metadata.json")
    params_path = Path.join(model_dir, "params.etf")

    with {:ok, metadata_json} <- File.read(metadata_path),
         {:ok, metadata} <- Jason.decode(metadata_json),
         {:ok, params_binary} <- File.read(params_path),
         {:ok, embedder} <-
           EmbeddingRuntime.load(
             encoder_model_dir:
               Keyword.get(opts, :encoder_model_dir, Map.fetch!(metadata, "encoder_model_dir"))
           ) do
      model =
        RerankerTrainer.build_model(
          Map.fetch!(metadata, "feature_dim"),
          Map.fetch!(metadata, "hidden_dim")
        )

      {:ok,
       %__MODULE__{
         embedder: embedder,
         model: model,
         model_state: :erlang.binary_to_term(params_binary)
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec score_batch(t(), [{binary(), binary()}]) :: {:ok, [float()]} | {:error, term()}
  def score_batch(%__MODULE__{} = runtime, pairs) do
    examples =
      Enum.map(pairs, fn {query, tool_card} ->
        %{query: query, tool_card: tool_card}
      end)

    with {:ok, features} <- FeatureBuilder.build_matrix(runtime.embedder, examples) do
      scores =
        runtime.model
        |> RerankerTrainer.predict(runtime.model_state, features)
        |> Nx.to_flat_list()
        |> Enum.map(fn
          value when is_float(value) -> value
          value when is_integer(value) -> value / 1
        end)

      {:ok, scores}
    end
  end
end
