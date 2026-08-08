defmodule SpectreKinetic.PlannerTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Planner
  alias SpectreKinetic.Planner.RegistryStore
  alias SpectreKinetic.TelemetryHelper

  @retrieval_fallback_event [:spectre_kinetic, :planner, :retrieval, :fallback]
  @reranker_fallback_event [:spectre_kinetic, :planner, :reranker, :fallback]

  defmodule FakeEmbedder do
    use GenServer

    def start_link(vector), do: GenServer.start_link(__MODULE__, vector)

    @impl GenServer
    def init(vector), do: {:ok, vector}

    @impl GenServer
    def handle_call({:embed_batch, texts}, _from, vector) do
      rows = Enum.map(texts, fn _text -> vector end)
      {:reply, {:ok, Nx.tensor(rows, type: :f32)}, vector}
    end
  end

  defmodule FakeReranker do
    def score_batch(_runtime, pairs) do
      scores =
        pairs
        |> Enum.with_index()
        |> Enum.map(fn {_pair, index} -> index / max(length(pairs) - 1, 1) end)

      {:ok, scores}
    end
  end

  defmodule ErrorReranker do
    def score_batch(_runtime, _pairs), do: {:error, :reranker_down}
  end

  defmodule LowScoreReranker do
    def score_batch(_runtime, pairs), do: {:ok, Enum.map(pairs, fn _pair -> 0.4 end)}
  end

  defmodule InvalidShapeReranker do
    def score_batch(_runtime, _pairs), do: {:ok, [0.5]}
  end

  defmodule InvalidValueReranker do
    def score_batch(_runtime, pairs) do
      {:ok, pairs |> Enum.map(fn _pair -> 0.5 end) |> List.replace_at(0, 1.1)}
    end
  end

  defmodule RaisingReranker do
    def score_batch(_runtime, _pairs), do: raise("reranker crashed")
  end

  defmodule ThrowingReranker do
    def score_batch(_runtime, _pairs), do: throw(:reranker_threw)
  end

  defmodule ExitingReranker do
    def score_batch(_runtime, _pairs), do: exit(:reranker_exited)
  end

  defmodule UnexpectedReturnReranker do
    def score_batch(_runtime, _pairs), do: :unexpected
  end

  defmodule FaultyRegistry do
    def embedding_matrix(:invalid), do: :invalid
    def embedding_matrix(:raise), do: raise("registry read failed")
    def embedding_matrix(:invalid_actions), do: nil
    def all_actions(:invalid_actions), do: :invalid
  end

  setup do
    {:ok, store} = RegistryStore.start_link(name: nil)

    # Load test actions
    for action <- test_actions() do
      :ok = RegistryStore.add_action(store, action)
    end

    {:ok, store: store}
  end

  describe "plan/2 with lexical fallback (no embeddings)" do
    test "selects correct tool for email", %{store: store} do
      {:ok, result} =
        Planner.plan(
          ~s(SEND OUTBOUND EMAIL WITH: TO=user@test.com SUBJECT="Hello" BODY="World"),
          %{registry: store, embedder: nil}
        )

      assert result["selected_tool"] == "Dynamic.Email.send/3"
      assert result["status"] == "ok"
      assert result["args"]["to"] == "user@test.com"
      assert result["args"]["subject"] == "Hello"
      assert result["args"]["body"] == "World"
    end

    test "selects correct tool for SMS", %{store: store} do
      {:ok, result} =
        Planner.plan(
          "SEND OUTBOUND SMS WITH: TO=+15551234567 BODY=\"Code 123\"",
          %{registry: store, embedder: nil}
        )

      assert result["selected_tool"] == "Dynamic.Sms.send/2"
      assert result["status"] == "ok"
    end

    test "selects correct tool for delete note", %{store: store} do
      {:ok, result} =
        Planner.plan(
          "DELETE NOTE ENTRY WITH: ID=note-42",
          %{registry: store, embedder: nil}
        )

      assert result["selected_tool"] == "Dynamic.Note.delete/1"
      assert result["args"]["id"] == "note-42"
    end

    test "reports missing args", %{store: store} do
      {:ok, result} =
        Planner.plan(
          "SEND OUTBOUND EMAIL WITH: TO=user@test.com",
          %{registry: store, embedder: nil}
        )

      assert result["selected_tool"] == "Dynamic.Email.send/3"
      assert result["status"] == "MISSING_ARGS"
      assert "subject" in result["missing"]
      assert "body" in result["missing"]
    end

    test "marks mappings below mapping_threshold as ambiguous", %{store: store} do
      {:ok, result} =
        Planner.plan(
          "SEND OUTBOUND EMAIL WITH: TO=user@test.com",
          %{registry: store, embedder: nil, mapping_threshold: 0.8}
        )

      assert result["status"] == "AMBIGUOUS_MAPPING"
      assert result["selected_tool"] == "Dynamic.Email.send/3"
      assert_in_delta result["mapping_score"], 1 / 3, 0.001
      assert Enum.sort(result["missing"]) == ["body", "subject"]
    end

    test "keeps the missing-args status when mapping reaches mapping_threshold", %{store: store} do
      {:ok, result} =
        Planner.plan(
          "SEND OUTBOUND EMAIL WITH: TO=user@test.com",
          %{registry: store, embedder: nil, mapping_threshold: 0.3}
        )

      assert result["status"] == "MISSING_ARGS"
      assert result["mapping_score"] >= 0.3
    end

    test "positional fallback remains ambiguous at the default threshold", %{store: store} do
      {:ok, result} =
        Planner.plan(
          "DELETE NOTE ENTRY WITH: UNKNOWN=note-42",
          %{registry: store, embedder: nil}
        )

      assert result["selected_tool"] == "Dynamic.Note.delete/1"
      assert result["args"] == %{"id" => "note-42"}
      assert result["status"] == "AMBIGUOUS_MAPPING"
      assert result["mapping_score"] == 0.5
      assert "low-confidence positional slot mapping" in result["notes"]
    end

    test "an invalid optional argument keeps the action non-executable", %{store: store} do
      :ok =
        RegistryStore.add_action(store, %{
          id: "Dynamic.Worker.configure/2",
          module: "Dynamic.Worker",
          name: "configure",
          arity: 2,
          doc: "Configure a retry worker",
          args: [
            %{name: "name", type: "String.t()", required: true, aliases: []},
            %{name: "retries", type: "pos_integer()", required: false, aliases: []}
          ],
          examples: ["CONFIGURE RETRY WORKER WITH: NAME=mailer RETRIES=3"]
        })

      assert {:ok, result} =
               Planner.plan(
                 "CONFIGURE RETRY WORKER WITH: NAME=mailer RETRIES=many",
                 %{registry: store, embedder: nil, tool_threshold: 0.0}
               )

      assert result["selected_tool"] == "Dynamic.Worker.configure/2"
      assert result["status"] == "AMBIGUOUS_MAPPING"
      assert result["missing"] == []

      assert result["invalid"] == [
               %{name: "retries", expected_type: "pos_integer()", reason: :type_mismatch}
             ]
    end

    test "returns NO_TOOL for garbage input with high threshold", %{store: store} do
      {:ok, result} =
        Planner.plan(
          "XYZZY FROBNICATE THE QUUX",
          %{registry: store, embedder: nil, tool_threshold: 0.99}
        )

      assert result["status"] == "NO_TOOL"
    end

    test "returns candidates list", %{store: store} do
      {:ok, result} =
        Planner.plan(
          ~s(SEND OUTBOUND EMAIL WITH: TO=user@test.com SUBJECT="Hi" BODY="Hello"),
          %{registry: store, embedder: nil}
        )

      assert is_list(result["candidates"])
      assert result["candidates"] != []
    end

    test "uses embedding matrix when registry and embedder provide one", %{store: store} do
      :ok =
        install_test_embeddings(store, %{
          "Dynamic.Sms.send/2" => [1.0, 0.0]
        })

      {:ok, embedder} = FakeEmbedder.start_link([1.0, 0.0])

      {:ok, result} =
        Planner.plan(
          "ROUTE MESSAGE SOMEWHERE WITH: TO=+15551234567 BODY=\"Code 123\"",
          %{registry: store, embedder: embedder, tool_threshold: 0.0}
        )

      assert result["selected_tool"] == "Dynamic.Sms.send/2"
      assert result["tool_score"] == 1.0
    end

    test "emits telemetry when embedded retrieval falls back to lexical", %{store: store} do
      :ok = install_test_embeddings(store)

      {result, events} =
        TelemetryHelper.capture([@retrieval_fallback_event], fn ->
          Planner.plan(
            ~s(SEND OUTBOUND EMAIL WITH: TO=user@test.com SUBJECT="Hello" BODY="World"),
            %{registry: store, embedder: nil}
          )
        end)

      assert {:ok, %{"selected_tool" => "Dynamic.Email.send/3"}} = result

      assert [%{measurements: measurements, metadata: metadata}] = events
      assert measurements.candidate_count > 0
      assert metadata.result == :fallback
      assert metadata.reason == :embedder_unavailable
    end

    test "emits telemetry when reranker fallback changes or confirms selection", %{store: store} do
      {result, events} =
        TelemetryHelper.capture([@reranker_fallback_event], fn ->
          Planner.plan(
            "SEND OUTBOUND MESSAGE WITH: TO=+15551234567 BODY=\"Code 123\"",
            %{
              registry: store,
              embedder: nil,
              tool_threshold: 0.0,
              tool_selection_fallback: :reranker,
              reranker: :fake,
              reranker_module: FakeReranker,
              fallback_margin: 1.0,
              reranker_threshold: 0.0
            }
          )
        end)

      assert {:ok, result} = result
      assert result["selected_tool"]

      assert [%{measurements: measurements, metadata: metadata}] = events
      assert measurements.candidate_count > 0
      assert metadata.result == :fallback
      assert metadata.primary_tool
      assert metadata.chosen_tool
    end

    test "emits telemetry when reranker fallback fails and primary selection is kept", %{
      store: store
    } do
      {_result, events} =
        TelemetryHelper.capture([@reranker_fallback_event], fn ->
          Planner.plan(
            "SEND OUTBOUND MESSAGE WITH: TO=+15551234567 BODY=\"Code 123\"",
            %{
              registry: store,
              embedder: nil,
              tool_threshold: 0.0,
              tool_selection_fallback: :reranker,
              reranker: :fake,
              reranker_module: ErrorReranker,
              fallback_margin: 1.0
            }
          )
        end)

      assert [%{metadata: metadata}] = events
      assert metadata.result == :error
      assert metadata.reason == :reranker_down
      assert metadata.primary_tool == metadata.chosen_tool
    end

    test "reranker exceptions fall back without crashing the planner", %{store: store} do
      {result, events} = plan_with_failing_reranker(store, RaisingReranker)

      assert {:ok, %{"selected_tool" => selected_tool}} = result
      assert is_binary(selected_tool)
      assert [%{metadata: metadata}] = events
      assert metadata.result == :error

      assert {:reranker_call_failed,
              %{
                kind: :raise,
                exception: RuntimeError,
                message: "reranker crashed"
              }} = metadata.reason
    end

    test "reranker throws and exits fall back without crashing the planner", %{store: store} do
      for {module, kind, reason} <- [
            {ThrowingReranker, :throw, :reranker_threw},
            {ExitingReranker, :exit, :reranker_exited}
          ] do
        {result, events} = plan_with_failing_reranker(store, module)

        assert {:ok, %{"selected_tool" => selected_tool}} = result
        assert is_binary(selected_tool)
        assert [%{metadata: metadata}] = events
        assert metadata.result == :error

        assert {:reranker_call_failed, %{kind: ^kind, reason: ^reason}} = metadata.reason
      end
    end

    test "unexpected reranker returns fall back without crashing the planner", %{store: store} do
      {result, events} = plan_with_failing_reranker(store, UnexpectedReturnReranker)

      assert {:ok, %{"selected_tool" => selected_tool}} = result
      assert is_binary(selected_tool)
      assert [%{metadata: metadata}] = events
      assert metadata.result == :error
      assert metadata.reason == {:invalid_reranker_return, :unexpected}
    end

    test "reranker cannot bypass the first-stage tool threshold", %{store: store} do
      {:ok, result} =
        Planner.plan(
          "SEND OUTBOUND MESSAGE WITH: TO=+15551234567 BODY=\"Code 123\"",
          %{
            registry: store,
            embedder: nil,
            tool_threshold: 0.99,
            tool_selection_fallback: :reranker,
            reranker: :fake,
            reranker_module: FakeReranker,
            reranker_threshold: 0.0
          }
        )

      assert result["status"] == "NO_TOOL"
      assert result["selected_tool"] == nil
    end

    test "reranker score must meet its explicit acceptance threshold", %{store: store} do
      {:ok, result} =
        Planner.plan(
          "SEND OUTBOUND MESSAGE WITH: TO=+15551234567 BODY=\"Code 123\"",
          %{
            registry: store,
            embedder: nil,
            tool_threshold: 0.0,
            tool_selection_fallback: :reranker,
            reranker: :fake,
            reranker_module: LowScoreReranker,
            fallback_margin: 1.0,
            reranker_threshold: 0.5
          }
        )

      assert result["status"] == "NO_TOOL"
      assert result["selected_tool"] == nil
    end

    test "invalid reranker score shape falls back safely", %{store: store} do
      {result, events} =
        TelemetryHelper.capture([@reranker_fallback_event], fn ->
          Planner.plan(
            "SEND OUTBOUND MESSAGE WITH: TO=+15551234567 BODY=\"Code 123\"",
            %{
              registry: store,
              embedder: nil,
              tool_threshold: 0.0,
              tool_selection_fallback: :reranker,
              reranker: :fake,
              reranker_module: InvalidShapeReranker,
              fallback_margin: 1.0
            }
          )
        end)

      assert {:ok, %{"selected_tool" => selected_tool}} = result
      assert is_binary(selected_tool)

      assert [%{metadata: metadata}] = events
      assert metadata.result == :error

      assert {:invalid_reranker_scores, {:score_count_mismatch, %{expected: expected, actual: 1}}} =
               metadata.reason

      assert expected > 1
    end

    test "non-finite or out-of-range reranker scores fall back safely", %{store: store} do
      {_result, events} =
        TelemetryHelper.capture([@reranker_fallback_event], fn ->
          Planner.plan(
            "SEND OUTBOUND MESSAGE WITH: TO=+15551234567 BODY=\"Code 123\"",
            %{
              registry: store,
              embedder: nil,
              tool_threshold: 0.0,
              tool_selection_fallback: :reranker,
              reranker: :fake,
              reranker_module: InvalidValueReranker,
              fallback_margin: 1.0
            }
          )
        end)

      assert [%{metadata: metadata}] = events
      assert metadata.result == :error

      assert {:invalid_reranker_scores, {:invalid_score, %{index: 0, value: 1.1}}} =
               metadata.reason
    end
  end

  defp plan_with_failing_reranker(store, reranker_module) do
    TelemetryHelper.capture([@reranker_fallback_event], fn ->
      Planner.plan(
        "SEND OUTBOUND MESSAGE WITH: TO=+15551234567 BODY=\"Code 123\"",
        %{
          registry: store,
          embedder: nil,
          tool_threshold: 0.0,
          tool_selection_fallback: :reranker,
          reranker: :fake,
          reranker_module: reranker_module,
          fallback_margin: 1.0
        }
      )
    end)
  end

  describe "plan_request/2" do
    test "works with explicit request map", %{store: store} do
      {:ok, result} =
        Planner.plan_request(
          %{"al" => "DELETE NOTE ENTRY WITH: ID=note-1", "slots" => %{"id" => "note-1"}},
          %{registry: store, embedder: nil}
        )

      assert result["selected_tool"] == "Dynamic.Note.delete/1"
      assert result["args"]["id"] == "note-1"
    end

    test "propagates all fallback request overrides", %{store: store} do
      request = %{
        "al" => "SEND OUTBOUND MESSAGE WITH: TO=+15551234567 BODY=\"Code 123\"",
        "tool_threshold" => 0.0,
        "tool_selection_fallback" => "reranker",
        "fallback_top_k" => 2,
        "fallback_margin" => 1.0,
        "reranker_threshold" => 0.0
      }

      {result, events} =
        TelemetryHelper.capture([@reranker_fallback_event], fn ->
          Planner.plan_request(request, %{
            registry: store,
            embedder: nil,
            tool_selection_fallback: :disabled,
            reranker: :fake,
            reranker_module: FakeReranker
          })
        end)

      assert {:ok, %{"selected_tool" => selected_tool}} = result
      assert is_binary(selected_tool)

      assert [%{measurements: measurements}] = events
      assert measurements.candidate_count == 2
      assert measurements.fallback_top_k == 2
      assert measurements.reranker_threshold == 0.0
    end

    test "preserves configured top_k when the request omits it", %{store: store} do
      request = %{
        "al" => "DELETE NOTE ENTRY WITH: ID=note-1",
        "slots" => %{"id" => "note-1"}
      }

      {result, events} =
        TelemetryHelper.capture([@retrieval_fallback_event], fn ->
          Planner.plan_request(request, %{registry: store, embedder: nil, top_k: 1})
        end)

      assert {:ok, %{"selected_tool" => "Dynamic.Note.delete/1"}} = result
      assert [%{measurements: %{candidate_count: 1, fallback_top_k: 1}}] = events

      {_result, events} =
        TelemetryHelper.capture([@retrieval_fallback_event], fn ->
          Planner.plan_request(Map.put(request, "top_k", 2), %{
            registry: store,
            embedder: nil,
            top_k: 1
          })
        end)

      assert [%{measurements: %{candidate_count: 2, fallback_top_k: 2}}] = events
    end
  end

  test "direct planner returns structured validation errors" do
    assert {:error,
            {:invalid_options,
             [
               %{field: :slots, reason: :must_be_map},
               %{field: :top_k, reason: :must_be_positive_integer},
               %{field: :tool_threshold, reason: :must_be_probability}
             ]}} =
             Planner.plan("SEND MESSAGE", %{slots: [], top_k: 0, tool_threshold: 1.5})

    assert {:error, {:invalid_request, [%{field: :al, reason: :invalid_al_verb}]}} =
             Planner.plan("123 SEND MESSAGE", %{})
  end

  test "embedded retrieval rejects incompatible query dimensions", %{store: store} do
    Enum.each(RegistryStore.all_actions(store), fn action ->
      assert :ok =
               RegistryStore.put_embedding(
                 store,
                 action["id"],
                 Nx.tensor([1.0, 0.0], type: :f32)
               )
    end)

    {:ok, embedder} = FakeEmbedder.start_link([1.0, 0.0, 0.0])

    assert {:error, {:embedding_dimension_mismatch, 3, 2}} =
             Planner.plan("SEND MESSAGE", %{
               registry: store,
               embedder: embedder,
               top_k: 1
             })
  end

  test "retrieval contains faulty registry reads" do
    assert Planner.plan("SEND MESSAGE", %{
             registry_module: FaultyRegistry,
             registry: :invalid
           }) == {:error, {:invalid_registry_return, :embedding_matrix, :invalid}}

    assert {:error,
            {:registry_backend_failed, :embedding_matrix,
             {:raise, RuntimeError, "registry read failed"}}} =
             Planner.plan("SEND MESSAGE", %{
               registry_module: FaultyRegistry,
               registry: :raise
             })

    assert Planner.plan("SEND MESSAGE", %{
             registry_module: FaultyRegistry,
             registry: :invalid_actions
           }) == {:error, {:invalid_registry_return, :all_actions, :invalid}}
  end

  # Production registries expose a matrix only when every action has an
  # embedding. Keeping the fixture complete prevents tests from depending on a
  # partial index that would silently exclude valid actions from retrieval.
  @spec install_test_embeddings(GenServer.server(), %{optional(binary()) => [number()]}) :: :ok
  defp install_test_embeddings(store, overrides \\ %{}) do
    Enum.each(test_actions(), fn %{"id" => action_id} ->
      vector = Map.get(overrides, action_id, [0.0, 1.0])
      :ok = RegistryStore.put_embedding(store, action_id, Nx.tensor(vector))
    end)
  end

  defp test_actions do
    [
      %{
        "id" => "Dynamic.Email.send/3",
        "module" => "Dynamic.Email",
        "name" => "send",
        "arity" => 3,
        "doc" => "Send an outbound email message to an email recipient",
        "spec" => "send(to, subject, body)",
        "args" => [
          %{
            "name" => "to",
            "type" => "String.t()",
            "required" => true,
            "aliases" => ["recipient", "email"]
          },
          %{
            "name" => "subject",
            "type" => "String.t()",
            "required" => true,
            "aliases" => ["title"]
          },
          %{
            "name" => "body",
            "type" => "String.t()",
            "required" => true,
            "aliases" => ["message", "text"]
          }
        ],
        "examples" => [
          "SEND OUTBOUND EMAIL WITH: TO=user@example.com SUBJECT=\"Status\" BODY=\"Report\""
        ]
      },
      %{
        "id" => "Dynamic.Sms.send/2",
        "module" => "Dynamic.Sms",
        "name" => "send",
        "arity" => 2,
        "doc" => "Send an outbound SMS message to a phone recipient",
        "spec" => "send(to, body)",
        "args" => [
          %{
            "name" => "to",
            "type" => "String.t()",
            "required" => true,
            "aliases" => ["phone", "number"]
          },
          %{
            "name" => "body",
            "type" => "String.t()",
            "required" => true,
            "aliases" => ["message", "text"]
          }
        ],
        "examples" => ["SEND OUTBOUND SMS WITH: TO=+15551234567 BODY=\"Code\""]
      },
      %{
        "id" => "Dynamic.Note.delete/1",
        "module" => "Dynamic.Note",
        "name" => "delete",
        "arity" => 1,
        "doc" => "Delete a note entry identified by id",
        "spec" => "delete(id)",
        "args" => [
          %{"name" => "id", "type" => "String.t()", "required" => true, "aliases" => ["note_id"]}
        ],
        "examples" => ["DELETE NOTE ENTRY WITH: ID=note-1"]
      },
      %{
        "id" => "Dynamic.Note.insert/2",
        "module" => "Dynamic.Note",
        "name" => "insert",
        "arity" => 2,
        "doc" => "Insert a note entry with title and body content",
        "spec" => "insert(title, body)",
        "args" => [
          %{"name" => "title", "type" => "String.t()", "required" => true, "aliases" => ["name"]},
          %{
            "name" => "body",
            "type" => "String.t()",
            "required" => true,
            "aliases" => ["text", "content"]
          }
        ],
        "examples" => ["INSERT NOTE ENTRY WITH: TITLE=\"My note\" BODY=\"Content\""]
      },
      %{
        "id" => "Dynamic.Task.create/3",
        "module" => "Dynamic.Task",
        "name" => "create",
        "arity" => 3,
        "doc" => "Create a work task with title due date and priority",
        "spec" => "create(title, due, priority)",
        "args" => [
          %{"name" => "title", "type" => "String.t()", "required" => true, "aliases" => ["name"]},
          %{
            "name" => "due",
            "type" => "String.t()",
            "required" => true,
            "aliases" => ["deadline"]
          },
          %{
            "name" => "priority",
            "type" => "String.t()",
            "required" => true,
            "aliases" => ["severity"]
          }
        ],
        "examples" => ["CREATE WORK TASK WITH: TITLE=\"Task\" DUE=2026-05-01 PRIORITY=high"]
      }
    ]
  end
end
