defmodule SpectreKinetic.MixTaskContractTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.SpectreKinetic.Compile
  alias Mix.Tasks.SpectreKinetic.DownloadEncoder
  alias Mix.Tasks.SpectreKinetic.Extract
  alias Mix.Tasks.SpectreKinetic.Show
  alias Mix.Tasks.SpectreKinetic.TrainReranker
  alias SpectreKinetic.TestRegistryHelper

  @default_model "BAAI/bge-small-en-v1.5"
  @default_revision "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
  @encoder_files %{
    "model.onnx" => "fixture-onnx-model",
    "tokenizer.json" => ~s({"fixture":"tokenizer"}),
    "config.json" => ~s({"fixture":"config"})
  }

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  test "show reports artifact identity and resolves AL, response, and file inputs" do
    registry = TestRegistryHelper.registry_json()

    Show.run(["--registry-json", registry, "--format", "json"])
    summary = receive_json!()
    assert summary["version"] == SpectreKinetic.version()
    assert summary["action_count"] == 4
    assert summary["registry_json"] == registry

    Show.run([
      "--registry-json",
      registry,
      "--al",
      ~s(INSTALL PACKAGE WITH: PACKAGE="nginx"),
      "--slot",
      "package=nginx",
      "--slot",
      "optional",
      "--top-k",
      "2",
      "--tool-threshold",
      "0.0",
      "--mapping-threshold",
      "0.0"
    ])

    al_payload = receive_json!()
    assert al_payload["al"] == ~s(INSTALL PACKAGE WITH: PACKAGE="nginx")
    assert al_payload["action"]["selected_tool"] == "Linux.Apt.install/1"

    Show.run([
      "--registry-json",
      registry,
      "--text",
      "AL: LIST DIRECTORY WITH: PATH=/tmp"
    ])

    chain_payload = receive_json!()
    assert [%{"selected_tool" => "Linux.Coreutils.ls/1"}] = chain_payload["chain"]["actions"]

    input_path = tmp_file("show-input.al", "AL: INSTALL PACKAGE nginx VIA APT")

    Show.run([
      "--registry-json",
      registry,
      "--file",
      input_path,
      "--text",
      "AL: DELETE THIS IGNORED VALUE"
    ])

    file_payload = receive_json!()
    assert [%{"selected_tool" => "Linux.Apt.install/1"}] = file_payload["chain"]["actions"]
  end

  test "show and compile reject malformed CLI input before unsafe work" do
    assert_raise Mix.Error, ~r/invalid options/, fn ->
      Show.run(["--not-a-real-option"])
    end

    assert_raise Mix.Error, ~r/invalid options/, fn ->
      Compile.run(["--unknown"])
    end

    assert_raise Mix.Error, ~r/missing required option --registry/, fn ->
      Compile.run([])
    end

    assert_raise Mix.Error, ~r/missing required option --encoder/, fn ->
      Compile.run(["--registry", "registry.json"])
    end

    assert_raise Mix.Error, ~r/missing required option --out/, fn ->
      Compile.run(["--registry", "registry.json", "--encoder", "encoder"])
    end

    assert_raise Mix.Error, ~r/compilation failed/, fn ->
      Compile.run([
        "--registry",
        tmp_file("bad-registry.json", "{}"),
        "--encoder",
        "missing-encoder",
        "--out",
        tmp_path("registry.etf"),
        "--batch-size",
        "1"
      ])
    end
  end

  test "extract enforces app and artifact format boundaries" do
    assert_raise Mix.Error, ~r/invalid options/, fn ->
      Extract.run(["--unknown"])
    end

    assert_raise Mix.Error, ~r/missing required option --out/, fn ->
      Extract.run([])
    end

    assert_raise Mix.Error, ~r/unknown app/, fn ->
      Extract.run(["--app", "certainly_not_a_loaded_app", "--out", tmp_path("registry.json")])
    end

    assert_raise Mix.Error, ~r/unsupported output format/, fn ->
      Extract.run(["--app", "spectre_kinetic", "--out", tmp_path("registry.txt")])
    end

    assert_raise Mix.Error, ~r/missing required option --encoder for ETF output/, fn ->
      Extract.run(["--app", "spectre_kinetic", "--out", tmp_path("registry.etf")])
    end

    default_output = tmp_path("default-app-registry.json")
    Extract.run(["--out", default_output])
    assert %{"actions" => actions} = default_output |> File.read!() |> Jason.decode!()
    assert length(actions) >= 2

    assert_raise Mix.Error, ~r/tool extraction failed/, fn ->
      Extract.run([
        "--app",
        "spectre_kinetic",
        "--encoder",
        "missing-encoder",
        "--out",
        tmp_path("failed-registry.etf"),
        "--batch-size",
        "1"
      ])
    end
  end

  test "reranker task loads JSONL source rows and reports model-load failures" do
    assert_raise Mix.Error, ~r/invalid options/, fn ->
      TrainReranker.run(["--unknown"])
    end

    assert_raise Mix.Error, ~r/missing required option --encoder/, fn ->
      TrainReranker.run([])
    end

    assert_raise Mix.Error, ~r/missing required option --dataset/, fn ->
      TrainReranker.run(["--encoder", "missing"])
    end

    assert_raise Mix.Error, ~r/missing required option --out/, fn ->
      TrainReranker.run(["--encoder", "missing", "--dataset", "missing.jsonl"])
    end

    dataset =
      [
        %{"query" => "send mail", "tool_card" => "SEND EMAIL", "label" => 1},
        %{"query" => "send mail", "tool_card" => "LIST DIRECTORY", "label" => 0}
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)
      |> then(&(String.duplicate("\n", 2) <> &1 <> "\n"))
      |> write_tmp_file("reranker.jsonl")

    assert_raise Mix.Error, ~r/reranker training failed/, fn ->
      TrainReranker.run([
        "--encoder",
        tmp_path("missing-encoder"),
        "--dataset",
        dataset,
        "--out",
        tmp_path("reranker-output"),
        "--hidden-dim",
        "4",
        "--batch-size",
        "2",
        "--epochs",
        "1",
        "--learning-rate",
        "0.01"
      ])
    end
  end

  test "download task can verify an existing offline generation and reports lock failures" do
    out_dir = tmp_path("verified-encoder")
    File.mkdir_p!(out_dir)

    files =
      Map.new(@encoder_files, fn {file, content} ->
        File.write!(Path.join(out_dir, file), content)

        {file,
         %{
           "bytes" => byte_size(content),
           "sha256" => sha256(content),
           "source_url" => DownloadEncoder.hf_url(@default_model, @default_revision, file)
         }}
      end)

    File.write!(
      Path.join(out_dir, "encoder-manifest.json"),
      Jason.encode!(%{
        "schema_version" => 1,
        "model" => @default_model,
        "revision" => @default_revision,
        "files" => files
      })
    )

    DownloadEncoder.run(["--out", out_dir])

    messages = receive_all_info([])

    assert Enum.any?(
             messages,
             &String.contains?(&1, "manifest #{Path.join(out_dir, "encoder-manifest.json")}")
           )

    assert Enum.any?(messages, &String.contains?(&1, "Encoder model ready at #{out_dir}"))
    assert Enum.count(messages, &String.starts_with?(&1, "skip ")) == 3

    locked_dir = tmp_path("locked-encoder")
    File.mkdir_p!(Path.join(locked_dir, ".spectre-download.lock"))

    assert_raise Mix.Error, ~r/encoder download failed.*download_locked/, fn ->
      DownloadEncoder.run(["--out", locked_dir])
    end
  end

  test "deprecated task names remain explicit aliases of the 0.1.3 commands" do
    aliases = [
      {Mix.Tasks.CompileKinetic, "spectre_kinetic.compile", [], "compile_kinetic is deprecated"},
      {Mix.Tasks.ExtractKinetic, "spectre_kinetic.extract", ["--unknown"],
       "extract_kinetic is deprecated"},
      {Mix.Tasks.Spectre.DownloadEncoder, "spectre_kinetic.download_encoder", [],
       "spectre.download_encoder is deprecated"},
      {Mix.Tasks.Spectre.Show, "spectre_kinetic.show", ["--unknown"],
       "spectre.show is deprecated"},
      {Mix.Tasks.Spectre.TrainClassifier, "spectre_kinetic.train_classifier", [],
       "spectre.train_classifier is deprecated"},
      {Mix.Tasks.Spectre.TrainReranker, "spectre_kinetic.train_reranker", [],
       "spectre.train_reranker is deprecated"}
    ]

    Enum.each(aliases, fn {module, delegated_task, argv, warning} ->
      Mix.Task.reenable(delegated_task)
      assert_raise Mix.Error, fn -> module.run(argv) end
      assert_receive {:mix_shell, :info, [message]}
      assert message =~ warning
    end)
  end

  defp receive_json! do
    assert_receive {:mix_shell, :info, [json]}
    Jason.decode!(json)
  end

  defp receive_all_info(messages) do
    receive do
      {:mix_shell, :info, [message]} -> receive_all_info([message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp write_tmp_file(contents, name), do: tmp_file(name, contents)

  defp tmp_file(name, contents) do
    path = tmp_path(name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp tmp_path(name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "spectre-mix-task-contract-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    Path.join(root, name)
  end
end
