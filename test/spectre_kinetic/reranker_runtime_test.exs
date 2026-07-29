defmodule SpectreKinetic.RerankerRuntimeTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Reranker.Runtime

  test "decodes one score per input without output metadata" do
    assert {:ok, [0.25, 0.75]} =
             Runtime.decode_scores(Nx.tensor([[0.25], [0.75]], type: :f32))

    assert {:ok, [0.25, 0.75]} =
             Runtime.decode_scores({Nx.tensor([0.25, 0.75], type: :f32)})
  end

  test "requires an explicit score index for multiclass output" do
    output = Nx.tensor([[2.0, 4.0], [8.0, 1.0]], type: :f32)

    assert {:error, {:score_index_required, 2}} = Runtime.decode_scores(output)
    assert {:ok, [4.0, 1.0]} = Runtime.decode_scores(output, score_index: 1)

    assert {:error, {:score_index_out_of_range, 2, 2}} =
             Runtime.decode_scores(output, score_index: 2)
  end

  test "applies declared sigmoid and softmax transforms" do
    assert {:ok, [sigmoid_score]} =
             Runtime.decode_scores(Nx.tensor([0.0]), score_transform: :sigmoid)

    assert_in_delta sigmoid_score, 0.5, 1.0e-6

    assert {:ok, [softmax_score]} =
             Runtime.decode_scores(
               Nx.tensor([[0.0, 2.0]]),
               score_index: 1,
               score_transform: :softmax
             )

    assert_in_delta softmax_score, 0.880_797, 1.0e-6
  end

  test "rejects ambiguous outputs and unsupported shapes" do
    assert {:error, {:ambiguous_reranker_outputs, 2}} =
             Runtime.decode_scores({Nx.tensor([0.1]), Nx.tensor([0.9])})

    assert {:error, {:unsupported_reranker_output_shape, {1, 1, 1}}} =
             Runtime.decode_scores(Nx.tensor([[[0.5]]]))
  end

  test "validates runtime options before loading model files" do
    assert {:error, {:missing_option, :fallback_model_dir}} = Runtime.load([])

    assert {:error, {:invalid_option, :max_length, 0}} =
             Runtime.load(fallback_model_dir: "/tmp/missing", max_length: 0)

    assert {:error, {:invalid_option, :score_index, -1}} =
             Runtime.load(fallback_model_dir: "/tmp/missing", score_index: -1)

    assert {:error, {:invalid_option, :score_transform, :guess}} =
             Runtime.load(fallback_model_dir: "/tmp/missing", score_transform: :guess)

    assert {:error, {:invalid_option, :fallback_model_dir}} =
             Runtime.load(fallback_model_dir: 42)
  end

  test "empty batches, invalid output values, and single-class softmax fail explicitly" do
    runtime = %Runtime{
      model: :unused,
      tokenizer: :unused,
      max_length: 8,
      score_transform: :identity
    }

    assert Runtime.score_batch(runtime, []) == {:ok, []}
    assert Runtime.decode_scores(:not_a_tensor) == {:error, :invalid_reranker_output}

    assert Runtime.decode_scores(Nx.tensor([0.5]), score_transform: :softmax) ==
             {:error, {:invalid_score_transform, :softmax, 1}}

    assert {:ok, [negative]} =
             Runtime.decode_scores(Nx.tensor([-2.0]), score_transform: :sigmoid)

    assert_in_delta negative, 0.119_202_9, 1.0e-6
  end

  test "load and inference failures are converted into stable runtime errors" do
    root =
      Path.join(
        System.tmp_dir!(),
        "spectre-reranker-runtime-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    assert {:error, {:tokenizer_load_failed, _reason}} =
             Runtime.load(fallback_model_dir: root, max_length: 8)

    File.write!(Path.join(root, "tokenizer.json"), tokenizer_json())

    assert {:error, {:model_load_failed, _reason}} =
             Runtime.load(fallback_model_dir: root, max_length: 8)

    {:ok, tokenizer} = Tokenizers.Tokenizer.from_buffer(tokenizer_json())

    runtime = %Runtime{
      model: :not_an_ortex_model,
      tokenizer: tokenizer,
      max_length: 8,
      score_index: nil,
      score_transform: :identity
    }

    assert {:error, {:reranker_failed, _message}} =
             Runtime.score_batch(runtime, [{"hello", "tool card"}])

    assert {:error, {:reranker_failed, _message}} =
             Runtime.score(runtime, "hello", "tool card")
  end

  defp tokenizer_json do
    Jason.encode!(%{
      "version" => "1.0",
      "truncation" => nil,
      "padding" => nil,
      "added_tokens" => [],
      "normalizer" => nil,
      "pre_tokenizer" => %{"type" => "Whitespace"},
      "post_processor" => nil,
      "decoder" => nil,
      "model" => %{
        "type" => "WordLevel",
        "vocab" => %{"[UNK]" => 0, "hello" => 1, "tool" => 2, "card" => 3},
        "unk_token" => "[UNK]"
      }
    })
  end
end
