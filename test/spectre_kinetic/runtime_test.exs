defmodule SpectreKinetic.RuntimeTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Planner.Registry.ETS
  alias SpectreKinetic.Planner.Runtime, as: PlannerRuntime
  alias SpectreKinetic.TelemetryHelper

  @encoder_load_event [:spectre_kinetic, :runtime, :encoder, :load]
  @reranker_load_event [:spectre_kinetic, :runtime, :reranker, :load]
  @registry_reload_event [:spectre_kinetic, :runtime, :registry, :reload]
  @registry_add_event [:spectre_kinetic, :runtime, :registry, :add_action]
  @registry_delete_event [:spectre_kinetic, :runtime, :registry, :delete_action]
  @registry_embed_event [:spectre_kinetic, :runtime, :registry, :embed]

  defmodule ExplicitReranker do
    def load(_opts), do: {:error, :should_not_load_when_runtime_is_explicit}
  end

  defmodule FakeEncoder do
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

  test "load_runtime/1 emits skipped optional ML load telemetry" do
    registry_json = write_registry_json([email_action()])

    {result, events} =
      TelemetryHelper.capture([@encoder_load_event, @reranker_load_event], fn ->
        SpectreKinetic.load_runtime(registry_json: registry_json)
      end)

    assert {:ok, %PlannerRuntime{}} = result

    assert event_metadata(events, @encoder_load_event).result == :skipped
    assert event_metadata(events, @encoder_load_event).reason == :missing_encoder_model_dir

    assert event_metadata(events, @reranker_load_event).result == :skipped
    assert event_metadata(events, @reranker_load_event).reason == :fallback_disabled
  end

  test "load_runtime/1 builds a persistent runtime that can plan directly" do
    registry_json = write_registry_json([email_action(), note_delete_action()])

    assert {:ok, %PlannerRuntime{} = runtime} =
             SpectreKinetic.load_runtime(registry_json: registry_json)

    assert SpectreKinetic.action_count(runtime) == 2

    assert {:ok, action} =
             SpectreKinetic.plan(
               runtime,
               ~s(SEND OUTBOUND EMAIL WITH: TO=user@test.com SUBJECT="Hello" BODY="World")
             )

    assert action.selected_tool == "Dynamic.Email.send/3"
    assert action.status == :ok

    assert action.args == %{
             "to" => "user@test.com",
             "subject" => "Hello",
             "body" => "World"
           }
  end

  test "runtime mutation APIs return updated runtimes" do
    registry_json = write_registry_json([email_action()])
    {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: registry_json)

    assert {:ok, runtime} = SpectreKinetic.add_action(runtime, note_delete_action())
    assert SpectreKinetic.action_count(runtime) == 2
    assert runtime.registry_module.embedding_matrix(runtime.registry) == nil

    assert {:ok, action} = SpectreKinetic.plan(runtime, "DELETE NOTE ENTRY WITH: ID=note-42")
    assert action.selected_tool == "Dynamic.Note.delete/1"

    assert {:ok, true, runtime} =
             SpectreKinetic.delete_action(runtime, "Dynamic.Note.delete/1")

    assert SpectreKinetic.action_count(runtime) == 1
  end

  test "runtime reload swaps registry contents" do
    email_json = write_registry_json([email_action()])
    notes_json = write_registry_json([note_delete_action()])

    {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: email_json)
    assert SpectreKinetic.action_count(runtime) == 1

    assert {:ok, runtime} = SpectreKinetic.reload_registry(runtime, notes_json)
    assert SpectreKinetic.action_count(runtime) == 1

    assert {:ok, action} = SpectreKinetic.plan(runtime, "DELETE NOTE ENTRY WITH: ID=note-1")
    assert action.selected_tool == "Dynamic.Note.delete/1"
  end

  test "load_runtime/1 accepts compiled registries without requiring an encoder" do
    compiled_registry = write_compiled_registry([email_action()])

    assert {:ok, %PlannerRuntime{} = runtime} =
             SpectreKinetic.load_runtime(compiled_registry: compiled_registry)

    assert SpectreKinetic.action_count(runtime) == 1
    assert runtime.encoder == nil
    assert runtime.registry_module.embedding_matrix(runtime.registry) == nil
  end

  test "explicit reranker runtime wins over fallback model loading" do
    registry_json = write_registry_json([email_action()])

    {result, events} =
      TelemetryHelper.capture([@reranker_load_event], fn ->
        SpectreKinetic.load_runtime(
          registry_json: registry_json,
          tool_selection_fallback: :reranker,
          reranker: :already_loaded,
          fallback_runtime_module: ExplicitReranker
        )
      end)

    assert {:ok, %PlannerRuntime{} = runtime} = result

    assert runtime.reranker == :already_loaded
    assert runtime.reranker_module == ExplicitReranker
    assert event_metadata(events, @reranker_load_event).result == :ok
    assert event_metadata(events, @reranker_load_event).reason == :explicit_runtime
  end

  test "reload_registry/2 rejects unknown registry formats" do
    registry_json = write_registry_json([email_action()])
    {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: registry_json)

    {result, events} =
      TelemetryHelper.capture([@registry_reload_event], fn ->
        SpectreKinetic.reload_registry(runtime, "/tmp/registry.txt")
      end)

    assert {:error, :unknown_registry_format} = result

    metadata = event_metadata(events, @registry_reload_event)
    assert metadata.result == :error
    assert metadata.reason == :unknown_registry_format
    assert metadata.format == :unknown
  end

  test "runtime mutation emits registry and embedding telemetry" do
    registry_json = write_registry_json([email_action()])
    notes_json = write_registry_json([note_delete_action()])
    {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: registry_json)

    {result, events} =
      TelemetryHelper.capture([@registry_add_event, @registry_embed_event], fn ->
        SpectreKinetic.add_action(runtime, note_delete_action())
      end)

    assert {:ok, runtime} = result
    assert event_metadata(events, @registry_add_event).result == :ok

    embed_metadata = event_metadata(events, @registry_embed_event)
    assert embed_metadata.result == :skipped
    assert embed_metadata.reason == :no_encoder
    assert embed_metadata.scope == :action

    {result, events} =
      TelemetryHelper.capture([@registry_reload_event, @registry_embed_event], fn ->
        SpectreKinetic.reload_registry(runtime, notes_json)
      end)

    assert {:ok, runtime} = result
    assert event_metadata(events, @registry_reload_event).result == :ok
    assert event_metadata(events, @registry_reload_event).format == :json
    assert event_metadata(events, @registry_embed_event).scope == :reload

    {result, events} =
      TelemetryHelper.capture([@registry_delete_event], fn ->
        SpectreKinetic.delete_action(runtime, "Dynamic.Note.delete/1")
      end)

    assert {:ok, true, _runtime} = result
    assert event_metadata(events, @registry_delete_event).result == :ok
    assert event_metadata(events, @registry_delete_event).deleted == true
  end

  test "add_action/2 embeds and emits success when an encoder exists" do
    registry_json = write_registry_json([email_action()])
    {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: registry_json)
    {:ok, encoder} = FakeEncoder.start_link([1.0, 0.0])
    runtime = %{runtime | encoder: encoder}

    {result, events} =
      TelemetryHelper.capture([@registry_add_event, @registry_embed_event], fn ->
        SpectreKinetic.add_action(runtime, note_delete_action())
      end)

    assert {:ok, %PlannerRuntime{} = runtime} = result
    assert runtime.registry_module.embedding_matrix(runtime.registry) != nil

    assert event_metadata(events, @registry_add_event).embedding_attempted == true
    assert event_metadata(events, @registry_embed_event).result == :ok
    assert event_metadata(events, @registry_embed_event).scope == :action
  end

  test "ETS registry backend can be used directly without the compatibility server" do
    {:ok, registry} = ETS.new()

    try do
      assert {:ok, registry} = ETS.add_action(registry, email_action())
      assert ETS.action_count(registry) == 1
      assert ETS.get_action(registry, "Dynamic.Email.send/3")["name"] == "send"
      assert ETS.resolve_alias(registry, "recipient") == [{"Dynamic.Email.send/3", "to"}]

      assert {:ok, registry} =
               ETS.put_embedding(registry, "Dynamic.Email.send/3", Nx.tensor([1.0, 0.0, 0.0]))

      assert {matrix, ids} = ETS.embedding_matrix(registry)
      assert ids == ["Dynamic.Email.send/3"]
      assert Nx.shape(matrix) == {1, 3}
    after
      ETS.close(registry)
    end
  end

  defp write_registry_json(actions) do
    path =
      Path.join(System.tmp_dir!(), "spectre_runtime_#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(%{"actions" => actions}))
    path
  end

  defp write_compiled_registry(actions) do
    path =
      Path.join(System.tmp_dir!(), "spectre_runtime_#{System.unique_integer([:positive])}.etf")

    bundle = %{
      version: 1,
      actions: actions,
      action_ids: [],
      tool_embeddings: [],
      embedding_dim: nil,
      compiled_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(path, :erlang.term_to_binary(bundle, [:compressed]))
    path
  end

  defp event_metadata(events, event) do
    events
    |> Enum.find(&(&1.event == event))
    |> Map.fetch!(:metadata)
  end

  defp email_action do
    %{
      "id" => "Dynamic.Email.send/3",
      "module" => "Dynamic.Email",
      "name" => "send",
      "arity" => 3,
      "doc" => "Send an outbound email message",
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
    }
  end

  defp note_delete_action do
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
    }
  end
end
