defmodule SpectreKinetic.Classifiers.Internal.AxonClassifier do
  @moduledoc false

  alias SpectreKinetic.Classifiers.Internal.AxonRuntime
  alias SpectreKinetic.Classifiers.Internal.FeatureVector

  @type state ::
          %{required(:mode) => :heuristic, required(:opts) => keyword()}
          | %{
              required(:mode) => :axon,
              required(:opts) => keyword(),
              required(:runtime) => AxonRuntime.t()
            }

  @doc false
  defmacro __using__(opts) do
    classifier_id = Keyword.fetch!(opts, :id)
    feature_module = Keyword.fetch!(opts, :features)
    output = Keyword.fetch!(opts, :output)
    opt_keys = Keyword.get(opts, :opts, [])
    load_error = Keyword.get(opts, :load_error, "failed to load classifier")

    quote bind_quoted: [
            classifier_id: classifier_id,
            feature_module: feature_module,
            load_error: load_error,
            opt_keys: opt_keys,
            output: output
          ] do
      @behaviour SpectreKinetic.Classifier

      alias SpectreKinetic.Classifiers.Internal.AxonClassifier

      @axon_classifier_id classifier_id
      @axon_feature_module feature_module
      @axon_load_error load_error
      @axon_opt_keys opt_keys
      @axon_output output

      @impl true
      @doc false
      @spec init(keyword()) :: AxonClassifier.state()
      def init(opts) do
        AxonClassifier.init(__MODULE__, opts, @axon_opt_keys, @axon_load_error)
      end

      @doc """
      Returns the stable classifier id used in metadata and training tasks.
      """
      @spec classifier_id() :: binary()
      def classifier_id, do: @axon_classifier_id

      @doc """
      Returns the number of numeric features expected by the classifier model.
      """
      @spec feature_dim() :: pos_integer()
      def feature_dim, do: @axon_feature_module.dim()

      @doc """
      Returns feature names in vector order.
      """
      @spec feature_names() :: [atom()]
      def feature_names, do: @axon_feature_module.feature_names()

      @doc """
      Builds the Axon model for this classifier metadata.
      """
      @spec build_model(map()) :: Axon.t()
      def build_model(metadata) do
        AxonClassifier.build_model(__MODULE__, metadata, @axon_output)
      end

      defoverridable init: 1, build_model: 1
    end
  end

  @doc false
  @spec init(module(), keyword(), [atom()], binary()) :: state()
  def init(classifier, opts, opt_keys, load_error)
      when is_atom(classifier) and is_list(opts) and is_list(opt_keys) and is_binary(load_error) do
    plug_opts = Keyword.take(opts, opt_keys)

    cond do
      Keyword.get(opts, :fallback) == :heuristic ->
        %{mode: :heuristic, opts: opts}

      runtime = Keyword.get(opts, :runtime) ->
        %{mode: :axon, runtime: runtime, opts: plug_opts}

      true ->
        load_runtime!(classifier, opts, plug_opts, load_error)
    end
  end

  @doc false
  @spec build_model(module(), map(), :binary | :multiclass) :: Axon.t()
  def build_model(classifier, metadata, output) when is_atom(classifier) and is_map(metadata) do
    input_dim = AxonRuntime.feature_dim(metadata)
    hidden_dim = Map.get(metadata, "hidden_dim", 32)

    Axon.input("features", shape: {nil, input_dim})
    |> Axon.dense(hidden_dim, activation: :relu)
    |> output_layer(classifier, metadata, output)
  end

  @doc false
  @spec predict_one(AxonRuntime.t(), [number()]) :: {:ok, [float()]} | {:error, term()}
  def predict_one(%AxonRuntime{} = runtime, features) when is_list(features) do
    with {:ok, tensor} <- FeatureVector.tensor(features, AxonRuntime.feature_dim(runtime)) do
      AxonRuntime.predict_one(runtime, tensor)
    end
  end

  @spec load_runtime!(module(), keyword(), keyword(), binary()) :: state()
  defp load_runtime!(classifier, opts, plug_opts, load_error) do
    case AxonRuntime.load(classifier, opts) do
      {:ok, runtime} ->
        %{mode: :axon, runtime: runtime, opts: plug_opts}

      {:error, reason} ->
        raise ArgumentError, "#{load_error}: #{inspect(reason)}"
    end
  end

  @spec output_layer(Axon.t(), module(), map(), :binary | :multiclass) :: Axon.t()
  defp output_layer(model, _classifier, _metadata, :binary) do
    Axon.dense(model, 1, activation: :sigmoid)
  end

  defp output_layer(model, classifier, metadata, :multiclass) do
    label_count =
      metadata
      |> Map.get("labels", default_label_names(classifier))
      |> length()

    Axon.dense(model, label_count, activation: :softmax)
  end

  @spec default_label_names(module()) :: [binary()]
  defp default_label_names(classifier) do
    if function_exported?(classifier, :labels, 0) do
      classifier.labels()
      |> Enum.map(&Atom.to_string/1)
    else
      []
    end
  end
end
