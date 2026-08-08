defmodule SpectreKinetic.RuntimeBoundaryHardeningTest.ResponseEncoder do
  @moduledoc false

  use GenServer

  def start_link(response), do: GenServer.start_link(__MODULE__, response)

  @impl GenServer
  def init(response), do: {:ok, response}

  @impl GenServer
  def handle_call({:embed_batch, texts}, _from, response) do
    reply = if is_function(response, 1), do: response.(texts), else: response
    {:reply, reply, response}
  end
end

defmodule SpectreKinetic.RuntimeBoundaryHardeningTest.RejectEmbeddingBackend do
  @moduledoc false

  alias SpectreKinetic.Planner.Registry.ETS

  defdelegate embedding_matrix(registry), to: ETS
  defdelegate tool_cards(registry), to: ETS
  defdelegate action_count(registry), to: ETS

  def put_embedding(_registry, action_id, _tensor),
    do: {:error, {:embedding_write_rejected, action_id}}
end

defmodule SpectreKinetic.RuntimeBoundaryHardeningTest.ControlledBackend do
  @moduledoc false

  def new(opts) do
    mode = Keyword.get(opts, :mode, :ok)
    result(mode, :new, {:ok, %{mode: mode, test_pid: Keyword.get(opts, :test_pid)}})
  end

  def load_json(state, _path), do: result(state.mode, :load_json, {:ok, state})
  def load_compiled(state, _path), do: result(state.mode, :load_compiled, {:ok, state})
  def all_actions(state), do: result(state.mode, :all_actions, [])
  def get_action(state, _id), do: result(state.mode, :get_action, nil)
  def action_count(state), do: result(state.mode, :action_count, 0)
  def add_action(state, _action), do: result(state.mode, :add_action, {:ok, state})

  def delete_action(state, _id),
    do: result(state.mode, :delete_action, {{:ok, false}, state})

  def embedding_matrix(state), do: result(state.mode, :embedding_matrix, nil)

  def put_embedding(state, _id, _tensor),
    do: result(state.mode, :put_embedding, {:ok, state})

  def tool_cards(state), do: result(state.mode, :tool_cards, [])
  def resolve_alias(state, _name), do: result(state.mode, :resolve_alias, [])

  def close(state) do
    if state.test_pid, do: send(state.test_pid, {:backend_closed, state.mode})
    result(state.mode, :close, :ok)
  end

  defp result({operation, :error}, operation, _default), do: {:error, :controlled_error}
  defp result({operation, :invalid}, operation, _default), do: :invalid
  defp result({operation, :raise}, operation, _default), do: raise("controlled failure")
  defp result({operation, :throw}, operation, _default), do: throw(:controlled_failure)
  defp result(_mode, _operation, default), do: default
end

defmodule SpectreKinetic.RuntimeBoundaryHardeningTest do
  use ExUnit.Case, async: false

  alias SpectreKinetic.ONNX
  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Planner.Registry.ETS
  alias SpectreKinetic.Planner.RegistryStore
  alias SpectreKinetic.Planner.Runtime
  alias SpectreKinetic.Planner.Runtime.Embeddings
  alias SpectreKinetic.RuntimeBoundaryHardeningTest.ControlledBackend
  alias SpectreKinetic.RuntimeBoundaryHardeningTest.RejectEmbeddingBackend
  alias SpectreKinetic.RuntimeBoundaryHardeningTest.ResponseEncoder

  test "ONNX helpers normalize tokenizer inputs and close model-load failures" do
    trap_exits()
    root = tmp_dir("onnx-boundary")
    tokenizer_path = Path.join(root, "tokenizer.json")
    File.write!(tokenizer_path, tokenizer_json())

    assert {:ok, tokenizer} = ONNX.load_tokenizer(tokenizer_path, 8)
    assert {:ok, first} = Tokenizers.Tokenizer.encode(tokenizer, "hello")
    assert {:ok, second} = Tokenizers.Tokenizer.encode(tokenizer, "unknown")

    {ids, masks, types} = ONNX.input_tensors([first, second])
    assert Nx.shape(ids) == {2, 1}
    assert Nx.shape(masks) == {2, 1}
    assert Nx.shape(types) == {2, 1}
    assert ONNX.first_output({ids, masks}) == ids
    assert ONNX.normalize_number(2) == 2.0
    assert ONNX.normalize_number(2.5) == 2.5

    assert {:error, {:tokenizer_load_failed, _reason}} =
             ONNX.load_tokenizer(Path.join(root, "missing.json"), 8)

    assert {:error, {:model_load_failed, _reason}} =
             ONNX.load_model(Path.join(root, "missing.onnx"))

    assert {:error, {:model_load_failed, _reason}} =
             EmbeddingRuntime.load(encoder_model_dir: root, max_length: 8)

    assert {:error, _reason} =
             EmbeddingRuntime.start_link(
               encoder_model_dir: root,
               max_length: 8,
               name: nil
             )
  end

  test "embedding runtime wraps inference failures for both library and server shapes" do
    {:ok, tokenizer} = Tokenizers.Tokenizer.from_buffer(tokenizer_json())

    runtime = %EmbeddingRuntime{
      model: :not_an_ortex_model,
      tokenizer: tokenizer,
      max_length: 8,
      dim: 3
    }

    assert EmbeddingRuntime.dim(runtime) == 3
    assert {:error, {:embed_failed, _message}} = EmbeddingRuntime.embed(runtime, "hello")

    assert {:error, {:embed_failed, _message}} =
             EmbeddingRuntime.embed_batch(runtime, ["hello", "unknown"])

    assert {:reply, 3, ^runtime} = EmbeddingRuntime.handle_call(:dim, self(), runtime)

    assert {:reply, {:error, {:embed_failed, _message}}, ^runtime} =
             EmbeddingRuntime.handle_call({:embed_batch, ["hello"]}, self(), runtime)

    {:ok, malformed} = ResponseEncoder.start_link({:ok, :not_a_tensor})

    assert EmbeddingRuntime.embed_batch(malformed, ["hello"]) ==
             {:error, :invalid_embedding_batch}

    assert EmbeddingRuntime.embed(malformed, "hello") ==
             {:error, :invalid_embedding_batch}
  end

  test "registry embeddings are validated before any generation is mutated" do
    {:ok, registry} = ETS.new()
    on_exit(fn -> ETS.close(registry) end)
    {:ok, registry} = ETS.add_action(registry, action("Example", "run"))

    {:ok, encoder} =
      ResponseEncoder.start_link(fn texts ->
        {:ok, Nx.tensor(Enum.map(texts, fn _ -> [1.0, 0.0] end), type: :f32)}
      end)

    runtime = runtime(registry, encoder)

    assert {:ok, embedded} =
             Embeddings.embed_loaded_registry(runtime, registry_json: "registry.json")

    assert {matrix, ["Example.run/0"]} = ETS.embedding_matrix(embedded.registry)
    assert Nx.shape(matrix) == {1, 2}

    assert Embeddings.reembed_after_reload?(embedded, "registry.json")
    refute Embeddings.reembed_after_reload?(embedded, "registry.etf")

    assert {:ok, unchanged} = Embeddings.reembed_after_reload(embedded, "registry.etf")
    assert unchanged.registry == embedded.registry

    {:ok, empty_registry} = ETS.new()
    on_exit(fn -> ETS.close(empty_registry) end)

    assert {:ok, empty} =
             Embeddings.embed_loaded_registry(runtime(empty_registry, encoder),
               registry_json: "registry.json"
             )

    assert ETS.action_count(empty.registry) == 0

    assert {:ok, normalized, vector} =
             Embeddings.prepare_action(runtime, action("Example", "stop"))

    assert normalized["id"] == "Example.stop/0"
    assert Nx.shape(vector) == {2}

    no_encoder = %{runtime | encoder: nil}

    assert {:ok, normalized, nil} =
             Embeddings.prepare_action(no_encoder, action("Example", "stop"))

    assert normalized["id"] == "Example.stop/0"
  end

  test "bad encoder replies and backend failures never install partial embeddings" do
    cases = [
      {{:ok, Nx.tensor([1.0, 0.0])}, {:invalid_embedding_batch_shape, {2}, 1}},
      {{:ok, Nx.tensor([[1, 0]], type: :s64)}, {:invalid_embedding_batch_type, {:s, 64}}},
      {{:ok, :not_a_tensor}, :invalid_embedding_batch},
      {{:error, :encoder_down}, :encoder_down}
    ]

    Enum.each(cases, fn {reply, expected_reason} ->
      {:ok, registry} = ETS.new()
      {:ok, registry} = ETS.add_action(registry, action("Example", "run"))
      {:ok, encoder} = ResponseEncoder.start_link(reply)

      assert Embeddings.embed_loaded_registry(runtime(registry, encoder),
               registry_json: "registry.json"
             ) == {:error, expected_reason}

      assert ETS.embedding_matrix(registry) == nil
      assert :ok = ETS.close(registry)
    end)

    {:ok, registry} = ETS.new()
    {:ok, registry} = ETS.add_action(registry, action("Example", "run"))
    {:ok, encoder} = ResponseEncoder.start_link({:ok, Nx.tensor([[1.0, 0.0]])})

    rejected = %{
      runtime(registry, encoder)
      | registry_module: RejectEmbeddingBackend
    }

    assert Embeddings.embed_loaded_registry(rejected, registry_json: "registry.json") ==
             {:error, {:embedding_write_rejected, "Example.run/0"}}

    assert ETS.embedding_matrix(registry) == nil
    assert :ok = ETS.close(registry)

    {:ok, failing} = ResponseEncoder.start_link({:error, :single_embedding_failed})

    assert Embeddings.prepare_action(
             runtime(%{mode: :ok}, failing, ControlledBackend),
             action("Example", "stop")
           ) == {:error, :single_embedding_failed}

    assert Embeddings.prepare_action(runtime(%{mode: :ok}, nil, ControlledBackend), %{}) ==
             {:error, {:invalid_field, "module", :must_be_string}}
  end

  test "ETS registry enforces ownership, path, capacity, and embedding invariants" do
    {:ok, registry} = ETS.new()
    on_exit(fn -> ETS.close(registry) end)

    for path <- [:invalid, "", <<255>>, String.duplicate("x", 4_097), "bad\0path"] do
      assert ETS.load_json(registry, path) == {:error, {:invalid_registry_input, :path}}
      assert ETS.load_compiled(registry, path) == {:error, {:invalid_registry_input, :path}}
    end

    assert {:ok, registry} = ETS.add_action(registry, action("Example", "one"))
    assert {:ok, registry} = ETS.add_action(registry, action("Example", "two"))

    assert {:ok, registry} =
             ETS.put_embedding(registry, "Example.one/0", Nx.tensor([1.0, 0.0]))

    assert ETS.embedding_matrix(registry) == nil
    assert ETS.resolve_alias(registry, <<255>>) == []
    assert ETS.resolve_alias(registry, :not_binary) == []

    assert ETS.put_embedding(registry, "Example.one/0", :invalid) ==
             {:error, :invalid_embedding_tensor}

    assert ETS.put_embedding(registry, "Example.one/0", Nx.tensor([[1.0, 0.0]])) ==
             {:error, {:invalid_embedding_shape, {1, 2}}}

    assert ETS.put_embedding(registry, "Example.one/0", Nx.tensor([1, 0], type: :s64)) ==
             {:error, {:invalid_embedding_type, {:s, 64}}}

    assert {:ok, registry} =
             ETS.put_embedding(registry, "Example.two/0", Nx.tensor([0.0, 1.0]))

    assert ETS.put_embedding(registry, "Example.two/0", Nx.tensor([0.0, 1.0, 2.0])) ==
             {:error, {:embedding_dimension_mismatch, 3, 2}}

    owner = self()

    task =
      Task.async(fn ->
        %{
          load: ETS.load_json(registry, "registry.json"),
          compiled: ETS.load_compiled(registry, "registry.etf"),
          upsert: ETS.add_action(registry, action("Example", "three")),
          delete: ETS.delete_action(registry, "Example.one/0"),
          embedding: ETS.put_embedding(registry, "Example.one/0", Nx.tensor([1.0, 0.0])),
          close: ETS.close(registry)
        }
      end)

    denied = Task.await(task)

    Enum.each(denied, fn {_operation, result} ->
      assert result == {:error, {:registry_not_owner, owner}}
    end)

    assert ETS.action_count(registry) == 2
  end

  test "registry JSON and compiled bundles fail closed on structural mismatches" do
    {:ok, registry} = ETS.new()
    on_exit(fn -> ETS.close(registry) end)

    json_cases = [
      {"root-list.json", Jason.encode!([]), :invalid_registry},
      {"bad-actions.json", Jason.encode!(%{"actions" => %{}}), :invalid_registry_actions},
      {"bad-json.json", "{", {:invalid_artifact_json, :any}}
    ]

    Enum.each(json_cases, fn {name, contents, expected} ->
      path = write_file(name, contents)
      result = ETS.load_json(registry, path)

      case expected do
        {:invalid_artifact_json, :any} ->
          assert {:error, {:invalid_artifact_json, _reason}} = result

        reason ->
          assert result == {:error, reason}
      end
    end)

    bundle_cases = [
      {:invalid_bundle, :invalid_bundle},
      {%{version: 2, actions: [], tool_embeddings: :bad, action_ids: []},
       :invalid_embedding_entries},
      {%{version: 2, actions: [], tool_embeddings: [], action_ids: ["unknown"]},
       :embedding_count_mismatch},
      {%{
         version: 2,
         actions: [action("Example", "run")],
         tool_embeddings: [[1.0]],
         action_ids: [42],
         embedding_dim: 1,
         embedding_dtype: "f32"
       }, :invalid_embedding_action_id},
      {%{
         version: 2,
         actions: [action("Example", "run")],
         tool_embeddings: [[1.0]],
         action_ids: ["Other.run/0"],
         embedding_dim: 1,
         embedding_dtype: "f32"
       }, :unknown_embedding_action},
      {%{
         version: 2,
         actions: [action("Example", "run")],
         tool_embeddings: [[1.0]],
         action_ids: ["Example.run/0"],
         embedding_dim: 1,
         embedding_dtype: "f64"
       }, {:unsupported_embedding_dtype, "f64"}},
      {%{
         version: 2,
         actions: [action("Example", "run")],
         tool_embeddings: [[1.0]],
         action_ids: ["Example.run/0"],
         embedding_dim: 0,
         embedding_dtype: "f32"
       }, {:invalid_embedding_dim, 0}}
    ]

    Enum.each(bundle_cases, fn {bundle, expected} ->
      path = write_file("bundle.etf", :erlang.term_to_binary(bundle))
      assert ETS.load_compiled(registry, path) == {:error, expected}
      assert ETS.action_count(registry) == 0
    end)

    assert {:error, {:bad_etf, {:invalid_artifact_term, %ArgumentError{}}}} =
             ETS.load_compiled(registry, write_file("missing.etf", ""))
  end

  test "registry normalization rejects ambiguous or unbounded action language schemas" do
    valid = action("Example", "run")

    invalid_cases = [
      {42, :invalid_action},
      {%{valid | "module" => " "}, {:invalid_field, "module", :must_not_be_blank}},
      {%{valid | "name" => <<255>>}, {:invalid_field, "name", :must_be_utf8}},
      {%{valid | "arity" => -1}, {:invalid_field, "arity", :must_be_non_negative_integer}},
      {%{valid | "id" => 42}, {:invalid_field, "id", :must_be_string}},
      {Map.put(valid, "doc", 42), {:invalid_field, "doc", :must_be_string}},
      {%{valid | "args" => :invalid}, {:invalid_field, "args", :must_be_list}},
      {%{valid | "args" => [:invalid], "arity" => 1}, {:invalid_arg, 0, :must_be_map}},
      {%{
         valid
         | "args" => [%{"name" => "value", "type" => 42}],
           "arity" => 1,
           "id" => "Example.run/1"
       }, {:invalid_arg, 0, {:invalid_field, "type", :must_be_string}}},
      {%{
         valid
         | "args" => [%{"name" => "value", "required" => :yes}],
           "arity" => 1,
           "id" => "Example.run/1"
       }, {:invalid_arg, 0, {:invalid_field, "required", :must_be_boolean}}},
      {%{
         valid
         | "args" => [%{"name" => "value", "aliases" => ["same", "SAME"]}],
           "arity" => 1,
           "id" => "Example.run/1"
       }, {:invalid_arg, 0, {:duplicate_alias, 0}}},
      {%{valid | "examples" => :invalid}, {:invalid_field, "examples", :must_be_list}},
      {%{valid | "examples" => [42]},
       {:invalid_field, "examples", :must_contain_non_blank_strings}}
    ]

    Enum.each(invalid_cases, fn {raw, expected} ->
      assert Registry.normalize_action(raw) == {:error, expected}
    end)

    assert Registry.build_tool_card(%{
             "module" => "Example",
             "name" => "run",
             "args" => nil,
             "examples" => nil
           }) == "Example.run - "
  end

  test "compatibility RegistryStore converts faulty backend behavior into data errors" do
    trap_exits()

    assert {:error, :controlled_error} =
             RegistryStore.start_link(
               name: nil,
               registry_module: ControlledBackend,
               mode: {:new, :error}
             )

    assert {:error, {:invalid_registry_return, :new, :invalid}} =
             RegistryStore.start_link(
               name: nil,
               registry_module: ControlledBackend,
               mode: {:new, :invalid}
             )

    assert {:error, {:raise, RuntimeError, "controlled failure"}} =
             RegistryStore.start_link(
               name: nil,
               registry_module: ControlledBackend,
               mode: {:new, :raise}
             )

    for {mode, operation, call, expected} <- [
          {{:load_json, :error}, :load_json, fn store -> RegistryStore.load_json(store, "x") end,
           {:error, :controlled_error}},
          {{:load_json, :invalid}, :load_json,
           fn store -> RegistryStore.load_json(store, "x") end,
           {:error, {:invalid_registry_return, :load_json, :invalid}}},
          {{:load_json, :raise}, :load_json, fn store -> RegistryStore.load_json(store, "x") end,
           {:error,
            {:registry_backend_failed, :load_json, {:raise, RuntimeError, "controlled failure"}}}},
          {{:all_actions, :throw}, :all_actions, &RegistryStore.all_actions/1,
           {:error, {:registry_backend_failed, :all_actions, {:throw, :controlled_failure}}}},
          {{:delete_action, :error}, :delete_action,
           fn store -> RegistryStore.delete_action(store, "id") end, {:error, :controlled_error}},
          {{:delete_action, :invalid}, :delete_action,
           fn store -> RegistryStore.delete_action(store, "id") end,
           {:error, {:invalid_registry_return, :delete_action, :invalid}}}
        ] do
      assert {:ok, store} =
               RegistryStore.start_link(
                 name: nil,
                 registry_module: ControlledBackend,
                 mode: mode,
                 test_pid: self()
               )

      assert call.(store) == expected, "unexpected #{operation} boundary result"
      GenServer.stop(store)
      assert_receive {:backend_closed, ^mode}
    end

    assert {:ok, store} =
             RegistryStore.start_link(
               name: nil,
               registry_module: ControlledBackend,
               mode: :ok
             )

    for path <- [:invalid, "", <<255>>, String.duplicate("x", 4_097), "bad\0path"] do
      assert RegistryStore.load_json(store, path) ==
               {:error, {:invalid_registry_input, :path}}

      assert RegistryStore.load_compiled(store, path) ==
               {:error, {:invalid_registry_input, :path}}
    end

    for alias_name <- [:invalid, <<255>>, String.duplicate("x", 257)] do
      assert RegistryStore.resolve_alias(store, alias_name) ==
               {:error, {:invalid_registry_input, :alias}}
    end
  end

  test "library runtime contains faulty mutation backend behavior" do
    valid_action = action("Example", "run")

    assert Runtime.add_action(
             runtime(%{mode: {:add_action, :invalid}}, nil, ControlledBackend),
             valid_action
           ) == {:error, {:invalid_registry_return, :upsert_action, :invalid}}

    assert Runtime.add_action(
             runtime(%{mode: {:add_action, :raise}}, nil, ControlledBackend),
             valid_action
           ) == {:error, {:exception, "controlled failure"}}

    assert Runtime.delete_action(
             runtime(%{mode: {:delete_action, :invalid}}, nil, ControlledBackend),
             "Example.run/0"
           ) == {:error, {:invalid_registry_return, :delete_action, :invalid}}

    assert Runtime.delete_action(
             runtime(%{mode: {:delete_action, :raise}}, nil, ControlledBackend),
             "Example.run/0"
           ) == {:error, {:exception, "controlled failure"}}
  end

  defp runtime(registry, encoder, registry_module \\ ETS) do
    %Runtime{
      registry_module: registry_module,
      registry: registry,
      encoder: encoder,
      reranker_module: nil,
      reranker: nil,
      allow_empty_registry: true,
      defaults: [],
      classifiers: []
    }
  end

  defp action(module, name) do
    %{
      "id" => "#{module}.#{name}/0",
      "module" => module,
      "name" => name,
      "arity" => 0,
      "args" => [],
      "examples" => ["RUN #{String.upcase(name)}"]
    }
  end

  defp tokenizer_json do
    ~S({"version":"1.0","truncation":null,"padding":null,"added_tokens":[],"normalizer":null,"pre_tokenizer":{"type":"Whitespace"},"post_processor":null,"decoder":null,"model":{"type":"WordLevel","vocab":{"[UNK]":0,"hello":1},"unk_token":"[UNK]"}})
  end

  defp tmp_dir(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp write_file(name, contents) do
    path = Path.join(tmp_dir("runtime-hardening"), name)
    File.write!(path, contents)
    path
  end

  defp trap_exits do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)
  end
end
