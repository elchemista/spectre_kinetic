defmodule SpectreKinetic.Planner.Compiler do
  @moduledoc """
  Offline compiler that produces an Elixir-native registry bundle.

  Takes a `registry.json` and an encoder model directory, and produces a
  binary ETF file containing:

    * normalized action definitions
    * ordered action IDs
    * precomputed tool-card embeddings as data-only f32 rows

  This bundle is loaded at runtime by `RegistryStore` so that production
  boots do not need network access or model inference at startup.
  """

  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Registry.ETS

  require Logger

  @compiled_bundle_version 2
  @embedding_dtype "f32"
  @f32_max 3.402_823_466_385_288_6e38
  @max_embedding_dim 16_384
  @max_batch_size 1_024

  @doc """
  Compiles a registry bundle from JSON + encoder model.

  ## Options

    * `:registry_json` — path to source registry JSON (required)
    * `:encoder_model_dir` — path to encoder model directory (required)
    * `:output` — output path for the compiled `.etf` bundle (required)
    * `:batch_size` — embedding batch size (default 32)
  """
  @spec compile(keyword()) :: :ok | {:error, term()}
  def compile(opts) do
    with {:ok, actions} <- load_actions(opts),
         :ok <- validate_actions(actions),
         {:ok, encoder_model_dir} <- fetch_opt(opts, :encoder_model_dir),
         :ok <- validate_path(encoder_model_dir, :encoder_model_dir),
         {:ok, output_path} <- fetch_opt(opts, :output),
         :ok <- validate_path(output_path, :output),
         {:ok, batch_size} <- positive_integer_option(opts, :batch_size, 32),
         {:ok, embedding_module} <- embedding_module(opts) do
      compile_actions(
        actions,
        encoder_model_dir,
        output_path,
        batch_size,
        embedding_module
      )
    end
  end

  defp compile_actions(actions, encoder_model_dir, output_path, batch_size, embedding_module) do
    Logger.info("Compiling registry with #{length(actions)} actions")

    with {:ok, registry} <- registry_from_actions(actions) do
      try do
        with {:ok, embedder} <- load_embedder(embedding_module, encoder_model_dir) do
          do_compile(registry, embedder, output_path, batch_size, embedding_module)
        end
      rescue
        error -> {:error, {:registry_compile_failed, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:registry_compile_failed, {kind, reason}}}
      after
        ETS.close(registry)
      end
    end
  end

  defp load_embedder(embedding_module, encoder_model_dir) do
    case embedding_module.load(encoder_model_dir: encoder_model_dir) do
      {:ok, embedder} -> {:ok, embedder}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_embedding_load_result, other}}
    end
  end

  defp fetch_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp validate_actions([]), do: {:error, :empty_registry}
  defp validate_actions(actions) when is_list(actions), do: :ok

  defp validate_path(path, key) when is_binary(path) and path != "" do
    if String.trim(path) == "", do: {:error, {:invalid_option, key}}, else: :ok
  end

  defp validate_path(_path, key), do: {:error, {:invalid_option, key}}

  defp positive_integer_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 and value <= @max_batch_size -> {:ok, value}
      value -> {:error, {:invalid_option, key, value}}
    end
  end

  defp embedding_module(opts) do
    case Keyword.get(opts, :embedding_module, EmbeddingRuntime) do
      module when is_atom(module) -> {:ok, module}
      value -> {:error, {:invalid_option, :embedding_module, value}}
    end
  end

  defp load_actions(opts) do
    case Keyword.fetch(opts, :actions) do
      {:ok, actions} when is_list(actions) -> {:ok, actions}
      {:ok, _other} -> {:error, {:invalid_option, :actions}}
      :error -> load_actions_from_registry_json(opts)
    end
  end

  defp load_actions_from_registry_json(opts) do
    with {:ok, registry_json} <- fetch_opt(opts, :registry_json),
         {:ok, registry} <- ETS.new(registry_json: registry_json) do
      actions_from_registry(registry)
    end
  end

  defp actions_from_registry(registry) do
    {:ok, ETS.all_actions(registry)}
  after
    ETS.close(registry)
  end

  defp registry_from_actions(actions) do
    case ETS.new() do
      {:ok, registry} -> populate_registry(registry, actions)
      {:error, _reason} = error -> error
    end
  end

  defp populate_registry(registry, actions) do
    case add_actions_to_registry(registry, actions) do
      {:ok, _registry} = ok ->
        ok

      {:error, _reason} = error ->
        ETS.close(registry)
        error
    end
  rescue
    error ->
      ETS.close(registry)
      {:error, {:registry_population_failed, Exception.message(error)}}
  catch
    kind, reason ->
      ETS.close(registry)
      {:error, {:registry_population_failed, {kind, reason}}}
  end

  defp add_actions_to_registry(registry, actions) do
    Enum.reduce_while(actions, {:ok, registry}, fn action, {:ok, current_registry} ->
      case ETS.add_action(current_registry, action) do
        {:ok, updated_registry} -> {:cont, {:ok, updated_registry}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp do_compile(registry, embedder, output_path, batch_size, embedding_module) do
    actions = ETS.all_actions(registry)
    cards = ETS.tool_cards(registry)

    Logger.info("Embedding #{length(cards)} tool cards...")

    {action_ids, card_texts} = Enum.unzip(cards)
    embedding_dim = embedding_module.dim(embedder)

    with :ok <- validate_embedding_dim(embedding_dim),
         {:ok, tool_embeddings} <-
           embed_in_batches(
             embedder,
             card_texts,
             batch_size,
             embedding_dim,
             embedding_module
           ),
         {:ok, embedding_rows} <- serialize_embedding_rows(tool_embeddings) do
      bundle = %{
        "version" => @compiled_bundle_version,
        "actions" => actions,
        "action_ids" => action_ids,
        "tool_embeddings" => embedding_rows,
        "embedding_dim" => embedding_dim,
        "embedding_dtype" => @embedding_dtype,
        "compiled_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      binary = :erlang.term_to_binary(bundle, [:compressed])

      with :ok <- atomic_write(output_path, binary) do
        Logger.info("Compiled registry written to #{output_path} (#{byte_size(binary)} bytes)")
      end
    end
  end

  defp embed_in_batches(embedder, texts, batch_size, embedding_dim, embedding_module) do
    texts
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, tensors} ->
      case embedding_module.embed_batch(embedder, batch) do
        {:ok, %Nx.Tensor{} = tensor} ->
          case Nx.shape(tensor) do
            {rows, ^embedding_dim} when rows == length(batch) ->
              {:cont, {:ok, [tensor | tensors]}}

            shape ->
              {:halt,
               {:error,
                {:invalid_embedding_batch_shape, shape, {length(batch), embedding_dim}}}}
          end

        {:ok, invalid} ->
          {:halt, {:error, {:invalid_embedding_batch, invalid}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> concatenate_batches()
  end

  defp concatenate_batches({:ok, tensors}),
    do: {:ok, tensors |> Enum.reverse() |> Nx.concatenate()}

  defp concatenate_batches({:error, _reason} = error), do: error

  defp validate_embedding_dim(dim)
       when is_integer(dim) and dim > 0 and dim <= @max_embedding_dim,
       do: :ok
  defp validate_embedding_dim(dim), do: {:error, {:invalid_embedding_dim, dim}}

  defp atomic_write(output_path, binary) do
    output_dir = Path.dirname(output_path)
    temp_path = temporary_path(output_path)

    with :ok <- File.mkdir_p(output_dir) do
      try do
        with :ok <- File.write(temp_path, binary, [:binary, :exclusive]),
             :ok <- File.rename(temp_path, output_path) do
          :ok
        end
      after
        File.rm(temp_path)
      end
    end
  end

  defp temporary_path(output_path) do
    directory = Path.dirname(output_path)
    file_name = Path.basename(output_path)
    unique = System.unique_integer([:positive, :monotonic])
    Path.join(directory, ".#{file_name}.tmp-#{unique}")
  end

  defp serialize_embedding_rows(matrix) do
    {n, _dim} = Nx.shape(matrix)

    rows =
      matrix
      |> Nx.as_type(:f32)
      |> then(fn matrix ->
        for i <- 0..(n - 1) do
          matrix[i] |> Nx.backend_transfer() |> Nx.to_flat_list()
        end
      end)

    case Enum.find_index(rows, fn row ->
           Enum.any?(row, &(not finite_f32_number?(&1)))
         end) do
      nil -> {:ok, rows}
      index -> {:error, {:invalid_embedding_values, index}}
    end
  end

  defp finite_f32_number?(value) when is_number(value) do
    finite_number?(value) and abs(value) <= @f32_max
  end

  defp finite_f32_number?(_value), do: false
  defp finite_number?(value) when is_integer(value), do: true

  defp finite_number?(value) when is_float(value) do
    representation = value |> :erlang.float_to_binary([:compact]) |> String.downcase()
    representation not in ["nan", "inf", "-inf"]
  rescue
    _error -> false
  end
end
