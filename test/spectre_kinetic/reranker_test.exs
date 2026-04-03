defmodule SpectreKinetic.RerankerTest do
  use ExUnit.Case, async: false

  alias SpectreKinetic.Action
  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Reranker.Runtime.Axon, as: AxonRuntime
  alias SpectreKinetic.Reranker.Trainer
  alias SpectreKinetic.TestRegistryHelper

  defmodule DeterministicEmbedding do
    @moduledoc false

    def load(opts) do
      {:ok, {:deterministic_embedding, Keyword.fetch!(opts, :encoder_model_dir)}}
    end

    def embed_batch(_embedder, texts) when is_list(texts) do
      vectors =
        Enum.map(texts, fn text ->
          text
          |> String.downcase()
          |> vector()
        end)

      {:ok, Nx.tensor(vectors, type: :f32)}
    end

    defp vector(text) do
      cond do
        String.contains?(text, "@") or String.contains?(text, "email") ->
          [1.0, 0.0]

        String.match?(text, ~r/\+\d/) or
          String.contains?(text, "sms") or
            String.contains?(text, "phone") ->
          [0.0, 1.0]

        true ->
          [0.35, 0.35]
      end
    end
  end

  test "trainer persists artifacts and learns matching pair scores" do
    output_dir = tmp_dir("reranker-artifacts")
    examples = reranker_examples()

    assert {:ok, %{metadata: metadata, calibration: calibration}} =
             Trainer.train(
               examples,
               encoder_model_dir: "test://deterministic",
               output_dir: output_dir,
               embedding_module: DeterministicEmbedding,
               epochs: 30,
               hidden_dim: 16,
               batch_size: 4,
               learning_rate: 0.01,
               seed: 42
             )

    assert metadata.example_count == length(examples)
    assert metadata.feature_dim == 8
    assert calibration.positive_count == div(length(examples), 2)
    assert calibration.negative_count == div(length(examples), 2)
    assert File.exists?(Path.join(output_dir, "params.etf"))
    assert File.exists?(Path.join(output_dir, "metadata.json"))
    assert File.exists?(Path.join(output_dir, "calibration.json"))

    assert {:ok, runtime} =
             AxonRuntime.load(
               fallback_model_dir: output_dir,
               embedding_module: DeterministicEmbedding
             )

    assert {:ok, [email_match, email_mismatch, sms_match, sms_mismatch]} =
             AxonRuntime.score_batch(runtime, [
               {email_query(), email_tool_card()},
               {email_query(), sms_tool_card()},
               {sms_query(), sms_tool_card()},
               {sms_query(), email_tool_card()}
             ])

    assert email_match > email_mismatch
    assert sms_match > sms_mismatch
  end

  test "trained reranker improves ambiguous planner selection" do
    output_dir = tmp_dir("reranker-planner")

    assert {:ok, _artifacts} =
             Trainer.train(
               reranker_examples(),
               encoder_model_dir: "test://deterministic",
               output_dir: output_dir,
               embedding_module: DeterministicEmbedding,
               epochs: 30,
               hidden_dim: 16,
               batch_size: 4,
               learning_rate: 0.01,
               seed: 42
             )

    assert {:ok, reranker} =
             AxonRuntime.load(
               fallback_model_dir: output_dir,
               embedding_module: DeterministicEmbedding
             )

    runtime =
      SpectreKinetic.load_runtime!(
        registry_json: TestRegistryHelper.registry_json([email_action(), sms_action()]),
        tool_threshold: 0.95,
        tool_selection_fallback: :reranker,
        reranker: reranker,
        fallback_runtime_module: AxonRuntime
      )

    assert {:ok, %Action{} = action} =
             SpectreKinetic.plan(
               runtime,
               ~s(SEND MESSAGE WITH: TO="+15551234567" BODY="hello")
             )

    assert action.selected_tool == "Dynamic.Sms.send/2"
    assert Enum.any?(action.notes, &String.contains?(&1, "reranker fallback selected"))
    assert hd(action.alternatives).id == "Dynamic.Email.send/2"
  end

  defp reranker_examples do
    email_card = email_tool_card()
    sms_card = sms_tool_card()

    [
      %{query: email_query(), tool_card: email_card, label: 1},
      %{query: email_query(), tool_card: sms_card, label: 0},
      %{query: "EMAIL dev@example.com THE REPORT", tool_card: email_card, label: 1},
      %{query: "EMAIL dev@example.com THE REPORT", tool_card: sms_card, label: 0},
      %{query: "SEND MESSAGE TO dev@example.com", tool_card: email_card, label: 1},
      %{query: "SEND MESSAGE TO dev@example.com", tool_card: sms_card, label: 0},
      %{query: sms_query(), tool_card: sms_card, label: 1},
      %{query: sms_query(), tool_card: email_card, label: 0},
      %{query: "SMS +15551234567 THE REPORT", tool_card: sms_card, label: 1},
      %{query: "SMS +15551234567 THE REPORT", tool_card: email_card, label: 0},
      %{query: "TEXT +15551234567 ASAP", tool_card: sms_card, label: 1},
      %{query: "TEXT +15551234567 ASAP", tool_card: email_card, label: 0}
    ]
  end

  defp email_query, do: ~s(SEND MESSAGE WITH: TO="dev@example.com" BODY="hello")
  defp sms_query, do: ~s(SEND MESSAGE WITH: TO="+15551234567" BODY="hello")

  defp email_tool_card, do: Registry.build_tool_card(email_action())
  defp sms_tool_card, do: Registry.build_tool_card(sms_action())

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp email_action do
    %{
      "id" => "Dynamic.Email.send/2",
      "module" => "Dynamic.Email",
      "name" => "send",
      "arity" => 2,
      "doc" => "Send a message to an email recipient",
      "spec" => "send(to :: String.t(), body :: String.t()) :: :ok",
      "args" => [
        %{
          "name" => "to",
          "type" => "String.t()",
          "required" => true,
          "aliases" => ["recipient", "email"]
        },
        %{
          "name" => "body",
          "type" => "String.t()",
          "required" => true,
          "aliases" => ["message", "text"]
        }
      ],
      "examples" => ["SEND MESSAGE WITH: TO={to} BODY={body}"]
    }
  end

  defp sms_action do
    %{
      "id" => "Dynamic.Sms.send/2",
      "module" => "Dynamic.Sms",
      "name" => "send",
      "arity" => 2,
      "doc" => "Send a message to a phone recipient",
      "spec" => "send(to :: String.t(), body :: String.t()) :: :ok",
      "args" => [
        %{
          "name" => "to",
          "type" => "String.t()",
          "required" => true,
          "aliases" => ["recipient", "phone", "number"]
        },
        %{
          "name" => "body",
          "type" => "String.t()",
          "required" => true,
          "aliases" => ["message", "text"]
        }
      ],
      "examples" => ["SEND MESSAGE WITH: TO={to} BODY={body}"]
    }
  end
end
