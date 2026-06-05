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
      :ok = RegistryStore.put_embedding(store, "Dynamic.Email.send/3", Nx.tensor([0.0, 1.0]))
      :ok = RegistryStore.put_embedding(store, "Dynamic.Sms.send/2", Nx.tensor([1.0, 0.0]))
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
      :ok = RegistryStore.put_embedding(store, "Dynamic.Email.send/3", Nx.tensor([0.0, 1.0]))

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
              tool_threshold: 0.99,
              tool_selection_fallback: :reranker,
              reranker: :fake,
              reranker_module: FakeReranker
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
              tool_threshold: 0.99,
              tool_selection_fallback: :reranker,
              reranker: :fake,
              reranker_module: ErrorReranker
            }
          )
        end)

      assert [%{metadata: metadata}] = events
      assert metadata.result == :error
      assert metadata.reason == :reranker_down
      assert metadata.primary_tool == metadata.chosen_tool
    end
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
