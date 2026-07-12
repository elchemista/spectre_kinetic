defmodule SpectreKinetic.RuntimeTest do
  use ExUnit.Case, async: false

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

  defmodule CapturingReranker do
    def load(opts), do: {:ok, {:loaded_with, opts}}
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

  defmodule FailingEncoder do
    use GenServer

    def start_link(), do: GenServer.start_link(__MODULE__, nil)

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_call({:embed_batch, _texts}, _from, state) do
      {:reply, {:error, :embedding_failed}, state}
    end
  end

  defmodule FailingClassifier do
    def init(_opts), do: raise("classifier init failed")
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

  test "load_runtime/1 resolves a registry path from application config" do
    registry_json = write_registry_json([email_action()])
    previous = Application.get_env(:spectre_kinetic, :registry_json)
    Application.put_env(:spectre_kinetic, :registry_json, registry_json)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:spectre_kinetic, :registry_json)
      else
        Application.put_env(:spectre_kinetic, :registry_json, previous)
      end
    end)

    assert {:ok, %PlannerRuntime{} = runtime} = SpectreKinetic.load_runtime()
    assert SpectreKinetic.action_count(runtime) == 1
  end

  test "load_runtime/1 rejects an empty registry unless explicitly allowed" do
    registry_json = write_registry_json([])

    assert {:error, :empty_registry} =
             SpectreKinetic.load_runtime(registry_json: registry_json)

    assert {:ok, %PlannerRuntime{} = runtime} =
             SpectreKinetic.load_runtime(
               registry_json: registry_json,
               allow_empty_registry: true
             )

    assert SpectreKinetic.action_count(runtime) == 0
  end

  test "load_runtime/1 closes registry resources when component loading fails" do
    registry_json = write_registry_json([email_action()])
    table_count = owned_table_count()

    assert {:error, {FailingClassifier, %RuntimeError{message: "classifier init failed"}}} =
             SpectreKinetic.load_runtime(
               registry_json: registry_json,
               classifiers: [FailingClassifier]
             )

    assert owned_table_count() == table_count
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
    previous_registry = runtime.registry
    assert SpectreKinetic.action_count(runtime) == 1

    assert {:ok, runtime} = SpectreKinetic.reload_registry(runtime, notes_json)
    assert SpectreKinetic.action_count(runtime) == 1
    assert :ets.info(previous_registry.actions) == :undefined

    assert {:ok, action} = SpectreKinetic.plan(runtime, "DELETE NOTE ENTRY WITH: ID=note-1")
    assert action.selected_tool == "Dynamic.Note.delete/1"
  end

  test "runtime reload preserves the active registry when validation fails" do
    email_json = write_registry_json([email_action()])
    invalid_json = write_registry_json([note_delete_action(), %{}])

    {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: email_json)
    active_registry = runtime.registry

    assert {:error, {:invalid_action, 1, :missing_id}} =
             SpectreKinetic.reload_registry(runtime, invalid_json)

    assert :ets.info(active_registry.actions) != :undefined
    assert SpectreKinetic.action_count(runtime) == 1
    assert ETS.get_action(active_registry, "Dynamic.Email.send/3") != nil
    assert ETS.get_action(active_registry, "Dynamic.Note.delete/1") == nil
  end

  test "runtime reload preserves the active registry when embedding fails" do
    email_json = write_registry_json([email_action()])
    notes_json = write_registry_json([note_delete_action()])

    {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: email_json)
    {:ok, encoder} = FailingEncoder.start_link()
    runtime = %{runtime | encoder: encoder}
    active_registry = runtime.registry

    assert {:error, :embedding_failed} =
             SpectreKinetic.reload_registry(runtime, notes_json)

    assert :ets.info(active_registry.actions) != :undefined
    assert SpectreKinetic.action_count(runtime) == 1
    assert ETS.get_action(active_registry, "Dynamic.Email.send/3") != nil
    assert ETS.get_action(active_registry, "Dynamic.Note.delete/1") == nil
  end

  test "runtime reload preserves the active registry when the embedder exits" do
    email_json = write_registry_json([email_action()])
    notes_json = write_registry_json([note_delete_action()])

    {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: email_json)
    runtime = %{runtime | encoder: :missing_kinetic_encoder}
    active_registry = runtime.registry

    assert {:error, {:registry_stage_failed, {:exit, _reason}}} =
             SpectreKinetic.reload_registry(runtime, notes_json)

    assert :ets.info(active_registry.actions) != :undefined
    assert SpectreKinetic.action_count(runtime) == 1
    assert ETS.get_action(active_registry, "Dynamic.Email.send/3") != nil
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

  test "passes explicit ONNX output semantics to the reranker runtime" do
    registry_json = write_registry_json([email_action()])

    assert {:ok, %PlannerRuntime{} = runtime} =
             SpectreKinetic.load_runtime(
               registry_json: registry_json,
               tool_selection_fallback: :reranker,
               fallback_model_dir: "/tmp/reranker-model",
               fallback_runtime_module: CapturingReranker,
               reranker_max_length: 256,
               reranker_score_index: 1,
               reranker_score_transform: :softmax
             )

    assert {:loaded_with, opts} = runtime.reranker
    assert opts[:fallback_model_dir] == "/tmp/reranker-model"
    assert opts[:max_length] == 256
    assert opts[:score_index] == 1
    assert opts[:score_transform] == :softmax
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

    {:ok, registry} =
      ETS.put_embedding(runtime.registry, "Dynamic.Email.send/3", Nx.tensor([1.0, 0.0]))

    runtime = %{runtime | registry: registry, encoder: encoder}

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

  test "add_action/2 leaves an existing action unchanged when embedding fails" do
    registry_json = write_registry_json([email_action()])
    {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: registry_json)
    {:ok, encoder} = FailingEncoder.start_link()
    runtime = %{runtime | encoder: encoder}

    replacement =
      email_action()
      |> Map.put("doc", "Replacement that must not be committed")
      |> Map.update!("args", fn [to | rest] ->
        [Map.put(to, "aliases", ["destination"]) | rest]
      end)

    assert {:error, :embedding_failed} = SpectreKinetic.add_action(runtime, replacement)

    stored = ETS.get_action(runtime.registry, "Dynamic.Email.send/3")
    assert stored["doc"] == "Send an outbound email message"
    assert ETS.resolve_alias(runtime.registry, "recipient") == [{"Dynamic.Email.send/3", "to"}]
    assert ETS.resolve_alias(runtime.registry, "destination") == []
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

  test "close_runtime/1 releases registry tables and is idempotent" do
    registry_json = write_registry_json([email_action()])
    {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: registry_json)
    registry = runtime.registry

    assert :ok = SpectreKinetic.close_runtime(runtime)
    assert :ets.info(registry.actions) == :undefined
    assert :ok = SpectreKinetic.close_runtime(runtime)
  end

  test "process-owned runtimes reject mutations and closure from other processes" do
    registry_json = write_registry_json([email_action()])
    notes_json = write_registry_json([note_delete_action()])
    {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: registry_json)
    owner = self()

    task =
      Task.async(fn ->
        {
          SpectreKinetic.add_action(runtime, note_delete_action()),
          SpectreKinetic.delete_action(runtime, "Dynamic.Email.send/3"),
          SpectreKinetic.reload_registry(runtime, notes_json),
          SpectreKinetic.close_runtime(runtime)
        }
      end)

    assert {
             {:error, {:registry_not_owner, ^owner}},
             {:error, {:registry_not_owner, ^owner}},
             {:error, {:registry_not_owner, ^owner}},
             {:error, {:registry_not_owner, ^owner}}
           } = Task.await(task)

    assert SpectreKinetic.action_count(runtime) == 1
    assert :ets.info(runtime.registry.actions) != :undefined
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

  defp owned_table_count do
    owner = self()

    :ets.all()
    |> Enum.count(fn table -> :ets.info(table, :owner) == owner end)
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
