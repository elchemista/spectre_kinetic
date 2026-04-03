defmodule SpectreKinetic.Planner.ScorerTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Planner.Scorer

  describe "cosine_similarity/2" do
    test "identical vectors score 1.0" do
      query = Nx.tensor([1.0, 0.0, 0.0])
      matrix = Nx.tensor([[1.0, 0.0, 0.0]])
      [score] = Scorer.cosine_similarity(query, matrix) |> Nx.to_flat_list()
      assert_in_delta score, 1.0, 0.001
    end

    test "orthogonal vectors score 0.0" do
      query = Nx.tensor([1.0, 0.0, 0.0])
      matrix = Nx.tensor([[0.0, 1.0, 0.0]])
      [score] = Scorer.cosine_similarity(query, matrix) |> Nx.to_flat_list()
      assert_in_delta score, 0.0, 0.001
    end

    test "scores multiple candidates" do
      query = Nx.tensor([1.0, 0.0, 0.0])
      matrix = Nx.tensor([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.5, 0.5, 0.0]])

      scores = Scorer.cosine_similarity(query, matrix) |> Nx.to_flat_list()
      assert length(scores) == 3
      assert_in_delta Enum.at(scores, 0), 1.0, 0.001
      assert_in_delta Enum.at(scores, 1), 0.0, 0.001
      assert Enum.at(scores, 2) > 0.0
    end
  end

  describe "top_k/2" do
    test "returns top k indices and scores" do
      scores = Nx.tensor([0.1, 0.9, 0.5, 0.3])
      result = Scorer.top_k(scores, 2)
      assert [{1, s1}, {2, s2}] = result
      assert_in_delta s1, 0.9, 0.001
      assert_in_delta s2, 0.5, 0.001
    end

    test "handles k larger than n" do
      scores = Nx.tensor([0.5, 0.3])
      result = Scorer.top_k(scores, 10)
      assert length(result) == 2
    end
  end

  describe "lexical_overlap/2" do
    test "full overlap returns 1.0" do
      assert_in_delta Scorer.lexical_overlap(
        "SEND EMAIL",
        "SEND EMAIL message"
      ), 1.0, 0.001
    end

    test "no overlap returns 0.0" do
      assert_in_delta Scorer.lexical_overlap(
        "DELETE TASK",
        "SEND EMAIL message"
      ), 0.0, 0.001
    end

    test "partial overlap" do
      score = Scorer.lexical_overlap(
        "SEND OUTBOUND EMAIL",
        "SEND EMAIL message to recipient"
      )
      assert score > 0.0 and score < 1.0
    end
  end

  describe "alias_overlap/2" do
    test "all slots match known args" do
      parsed = %{"to" => "test@test.com", "subject" => "Hi"}
      action = %{
        "args" => [
          %{"name" => "to", "aliases" => ["recipient"]},
          %{"name" => "subject", "aliases" => ["title"]}
        ]
      }
      assert_in_delta Scorer.alias_overlap(parsed, action), 1.0, 0.001
    end

    test "alias matches count" do
      parsed = %{"recipient" => "test@test.com"}
      action = %{
        "args" => [
          %{"name" => "to", "aliases" => ["recipient", "email"]}
        ]
      }
      assert_in_delta Scorer.alias_overlap(parsed, action), 1.0, 0.001
    end

    test "no match returns 0.0" do
      parsed = %{"foo" => "bar"}
      action = %{"args" => [%{"name" => "to", "aliases" => []}]}
      assert_in_delta Scorer.alias_overlap(parsed, action), 0.0, 0.001
    end

    test "empty args returns 0.0" do
      assert_in_delta Scorer.alias_overlap(%{}, %{"args" => []}), 0.0, 0.001
    end
  end

  describe "shape_score/2" do
    test "exact match returns 1.0" do
      parsed = %{"to" => "a", "subject" => "b"}
      action = %{"args" => [
        %{"name" => "to", "required" => true},
        %{"name" => "subject", "required" => true}
      ]}
      assert_in_delta Scorer.shape_score(parsed, action), 1.0, 0.001
    end

    test "missing required arg reduces score" do
      parsed = %{"to" => "a"}
      action = %{"args" => [
        %{"name" => "to", "required" => true},
        %{"name" => "subject", "required" => true}
      ]}
      assert Scorer.shape_score(parsed, action) < 1.0
    end
  end

  describe "fuse_scores/1" do
    test "all 1.0 returns 1.0" do
      assert_in_delta Scorer.fuse_scores(%{
        embedding: 1.0,
        lexical: 1.0,
        alias: 1.0,
        shape: 1.0
      }), 1.0, 0.001
    end

    test "all 0.0 returns 0.0" do
      assert_in_delta Scorer.fuse_scores(%{
        embedding: 0.0,
        lexical: 0.0,
        alias: 0.0,
        shape: 0.0
      }), 0.0, 0.001
    end
  end
end
