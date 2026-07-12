defmodule SpectreKinetic.DownloadEncoderTaskTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.SpectreKinetic.DownloadEncoder

  @default_model "BAAI/bge-small-en-v1.5"
  @default_revision "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
  @custom_revision "0123456789abcdef0123456789abcdef01234567"
  @fixtures %{
    "model.onnx" => "fixture-onnx-model",
    "tokenizer.json" => ~s({"fixture":"tokenizer"}),
    "config.json" => ~s({"fixture":"config"})
  }

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "spectre-download-encoder-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  test "uses an immutable built-in revision for the default model" do
    opts = DownloadEncoder.options!(["--out", "artifacts/encoder"])

    assert opts[:model] == @default_model
    assert opts[:revision] == @default_revision

    assert DownloadEncoder.hf_url(opts[:model], opts[:revision], "model.onnx") ==
             "https://huggingface.co/#{@default_model}/resolve/#{@default_revision}/onnx/model.onnx"
  end

  test "requires a full commit revision for custom models" do
    assert_raise Mix.Error, ~r/missing required option --revision/, fn ->
      DownloadEncoder.options!(["--model", "acme/encoder", "--out", "tmp/encoder"])
    end

    opts =
      DownloadEncoder.options!([
        "--model",
        "acme/encoder",
        "--revision",
        String.upcase(@custom_revision),
        "--out",
        "tmp/encoder"
      ])

    assert opts[:revision] == @custom_revision

    assert DownloadEncoder.hf_url(opts[:model], opts[:revision], "config.json") ==
             "https://huggingface.co/acme/encoder/resolve/#{@custom_revision}/config.json"
  end

  test "rejects mutable, shortened, and malformed revisions" do
    for revision <- ["main", "5c38ec7", String.duplicate("g", 40), "../main"] do
      assert_raise Mix.Error, ~r/immutable 40-character hexadecimal commit SHA/, fn ->
        DownloadEncoder.options!([
          "--revision",
          revision,
          "--out",
          "tmp/encoder"
        ])
      end
    end
  end

  test "rejects model IDs, paths, positional arguments, and files outside the allowlist" do
    for model <- ["../private", "acme/model/extra", "https://example.com/model", "acme/model?x=1"] do
      assert_raise Mix.Error, ~r/invalid Hugging Face model ID/, fn ->
        DownloadEncoder.options!([
          "--model",
          model,
          "--revision",
          @custom_revision,
          "--out",
          "tmp/encoder"
        ])
      end
    end

    assert_raise Mix.Error, ~r/missing required option --out/, fn ->
      DownloadEncoder.options!([])
    end

    assert_raise Mix.Error, ~r/unexpected arguments/, fn ->
      DownloadEncoder.options!(["--out", "tmp/encoder", "extra"])
    end

    assert_raise Mix.Error, ~r/unsupported encoder file/, fn ->
      DownloadEncoder.hf_url(@default_model, @default_revision, "../secret")
    end

    assert_raise Mix.Error, ~r/--checksum-manifest must be a non-empty filesystem path/, fn ->
      DownloadEncoder.options!([
        "--out",
        "tmp/encoder",
        "--checksum-manifest",
        " "
      ])
    end
  end

  test "stages downloads and writes a verifiable manifest", %{tmp_dir: tmp_dir} do
    out_dir = Path.join(tmp_dir, "encoder")
    test_pid = self()

    downloader = fn url, temporary ->
      refute File.exists?(Path.join(out_dir, fixture_name(url)))
      send(test_pid, {:downloaded_to, temporary})
      File.write(temporary, fixture_content(url))
    end

    opts =
      DownloadEncoder.options!(["--out", out_dir])
      |> Keyword.put(:downloader, downloader)

    assert {:ok, result} = DownloadEncoder.download(opts)

    for {file, content} <- @fixtures do
      assert File.read!(Path.join(out_dir, file)) == content
      assert_received {:downloaded_to, temporary}
      assert Path.dirname(temporary) != out_dir

      assert temporary
             |> Path.dirname()
             |> Path.basename()
             |> String.starts_with?(".spectre-download-")
    end

    assert result.manifest_path == Path.join(out_dir, "encoder-manifest.json")
    manifest = Jason.decode!(File.read!(result.manifest_path))
    assert manifest["schema_version"] == 1
    assert manifest["model"] == @default_model
    assert manifest["revision"] == @default_revision

    for {file, content} <- @fixtures do
      entry = manifest["files"][file]
      assert entry["bytes"] == byte_size(content)
      assert entry["sha256"] == sha256(content)

      assert entry["source_url"] ==
               DownloadEncoder.hf_url(@default_model, @default_revision, file)
    end

    assert staging_directories(out_dir) == []

    verified_out_dir = Path.join(tmp_dir, "verified-encoder")

    verified_opts =
      DownloadEncoder.options!([
        "--out",
        verified_out_dir,
        "--checksum-manifest",
        result.manifest_path
      ])
      |> Keyword.put(:downloader, &File.write(&2, fixture_content(&1)))

    assert {:ok, _verified_result} = DownloadEncoder.download(verified_opts)

    for {file, content} <- @fixtures do
      assert File.read!(Path.join(verified_out_dir, file)) == content
    end

    assert staging_directories(verified_out_dir) == []

    test_pid = self()

    rerun_opts =
      DownloadEncoder.options!(["--out", out_dir])
      |> Keyword.put(:downloader, fn _url, _temporary ->
        send(test_pid, :unexpected_rerun_download)
        {:error, :unexpected}
      end)

    assert {:ok, _rerun_result} = DownloadEncoder.download(rerun_opts)
    refute_received :unexpected_rerun_download
  end

  test "refuses to bless an unverified existing artifact", %{tmp_dir: tmp_dir} do
    out_dir = Path.join(tmp_dir, "legacy-encoder")
    File.mkdir_p!(out_dir)
    File.write!(Path.join(out_dir, "model.onnx"), "legacy-model")
    test_pid = self()

    opts =
      DownloadEncoder.options!(["--out", out_dir])
      |> Keyword.put(:downloader, fn _url, _temporary ->
        send(test_pid, :unexpected_legacy_download)
        :ok
      end)

    assert {:error, {:unverified_existing_artifacts, ["model.onnx"]}} =
             DownloadEncoder.download(opts)

    assert File.read!(Path.join(out_dir, "model.onnx")) == "legacy-model"
    refute File.exists?(Path.join(out_dir, "encoder-manifest.json"))
    refute_received :unexpected_legacy_download
  end

  test "uses an existing manifest even when no artifacts exist yet", %{tmp_dir: tmp_dir} do
    out_dir = Path.join(tmp_dir, "manifest-only")
    File.mkdir_p!(out_dir)

    checksums =
      Map.new(@fixtures, fn {file, content} ->
        {file, %{"sha256" => sha256(content)}}
      end)

    File.write!(
      Path.join(out_dir, "encoder-manifest.json"),
      Jason.encode!(trusted_manifest(checksums))
    )

    opts =
      DownloadEncoder.options!(["--out", out_dir])
      |> Keyword.put(:downloader, &File.write(&2, fixture_content(&1)))

    assert {:ok, _result} = DownloadEncoder.download(opts)

    for {file, content} <- @fixtures do
      assert File.read!(Path.join(out_dir, file)) == content
    end

    refute File.exists?(lock_path(out_dir))
  end

  test "validates skipped files before accepting their hashes", %{tmp_dir: tmp_dir} do
    out_dir = Path.join(tmp_dir, "empty-existing")
    File.mkdir_p!(out_dir)
    File.write!(Path.join(out_dir, "model.onnx"), "")

    checksum_manifest = Path.join(tmp_dir, "empty-manifest.json")

    checksums =
      @fixtures
      |> Map.put("model.onnx", "")
      |> Map.new(fn {file, content} -> {file, %{"sha256" => sha256(content)}} end)

    File.write!(checksum_manifest, Jason.encode!(trusted_manifest(checksums)))
    test_pid = self()

    opts =
      DownloadEncoder.options!([
        "--out",
        out_dir,
        "--checksum-manifest",
        checksum_manifest
      ])
      |> Keyword.put(:downloader, fn _url, _temporary ->
        send(test_pid, :unexpected_empty_download)
        :ok
      end)

    assert {:error, {:empty_download, empty_path}} = DownloadEncoder.download(opts)
    assert empty_path == Path.join(out_dir, "model.onnx")
    refute_received :unexpected_empty_download
    refute File.exists?(lock_path(out_dir))
  end

  test "rejects malformed JSON and Git LFS pointers before commit", %{tmp_dir: tmp_dir} do
    for {bad_file, bad_content, expected_reason} <- [
          {"model.onnx", "version https://git-lfs.github.com/spec/v1\noid sha256:abc\n",
           :git_lfs_pointer},
          {"model.onnx", "<!DOCTYPE html><title>not a model</title>", :html_response},
          {"tokenizer.json", "not-json", :invalid_json}
        ] do
      out_dir = Path.join(tmp_dir, "malformed-#{bad_file}")

      opts =
        DownloadEncoder.options!(["--out", out_dir])
        |> Keyword.put(:downloader, fn url, temporary ->
          file = fixture_name(url)
          File.write(temporary, if(file == bad_file, do: bad_content, else: fixture_content(url)))
        end)

      error = DownloadEncoder.download(opts)

      case expected_reason do
        :git_lfs_pointer ->
          assert {:error, {:invalid_model_artifact, _path, :git_lfs_pointer}} = error

        :html_response ->
          assert {:error, {:invalid_model_artifact, _path, :html_response}} = error

        :invalid_json ->
          assert {:error, {:invalid_json_artifact, "tokenizer.json", _path, _reason}} = error
      end

      for file <- Map.keys(@fixtures) ++ ["encoder-manifest.json"] do
        refute File.exists?(Path.join(out_dir, file))
      end

      assert staging_directories(out_dir) == []
      refute File.exists?(lock_path(out_dir))
    end
  end

  test "a checksum mismatch preserves every existing artifact and cleans staging", %{
    tmp_dir: tmp_dir
  } do
    out_dir = Path.join(tmp_dir, "encoder")
    File.mkdir_p!(out_dir)

    for file <- Map.keys(@fixtures) do
      File.write!(Path.join(out_dir, file), "old-#{file}")
    end

    old_manifest = ~s({"state":"old"})
    File.write!(Path.join(out_dir, "encoder-manifest.json"), old_manifest)

    checksums =
      Map.new(@fixtures, fn {file, content} ->
        checksum =
          if file == "tokenizer.json",
            do: String.duplicate("0", 64),
            else: sha256(content)

        {file, %{"sha256" => checksum}}
      end)

    checksum_manifest = Path.join(tmp_dir, "trusted-manifest.json")

    File.write!(
      checksum_manifest,
      Jason.encode!(trusted_manifest(checksums))
    )

    opts =
      DownloadEncoder.options!([
        "--out",
        out_dir,
        "--force",
        "--checksum-manifest",
        checksum_manifest
      ])
      |> Keyword.put(:downloader, fn url, temporary ->
        File.write(temporary, fixture_content(url))
      end)

    assert {:error, {:checksum_mismatch, "tokenizer.json", _expected, _actual}} =
             DownloadEncoder.download(opts)

    for file <- Map.keys(@fixtures) do
      assert File.read!(Path.join(out_dir, file)) == "old-#{file}"
    end

    assert File.read!(Path.join(out_dir, "encoder-manifest.json")) == old_manifest
    assert staging_directories(out_dir) == []
  end

  test "rolls back the full generation when any atomic rename fails", %{tmp_dir: tmp_dir} do
    for failure_index <- 1..4 do
      out_dir = Path.join(tmp_dir, "rename-failure-#{failure_index}")
      File.mkdir_p!(out_dir)

      for file <- Map.keys(@fixtures) do
        File.write!(Path.join(out_dir, file), "old-#{file}")
      end

      old_manifest = ~s({"generation":"old"})
      File.write!(Path.join(out_dir, "encoder-manifest.json"), old_manifest)
      counter = :counters.new(1, [])

      renamer = fn source, destination ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == failure_index do
          {:error, :injected_failure}
        else
          File.rename(source, destination)
        end
      end

      opts =
        DownloadEncoder.options!(["--out", out_dir, "--force"])
        |> Keyword.put(:downloader, &File.write(&2, fixture_content(&1)))
        |> Keyword.put(:renamer, renamer)

      assert {:error, {:atomic_rename_failed, _destination, :injected_failure}} =
               DownloadEncoder.download(opts)

      for file <- Map.keys(@fixtures) do
        assert File.read!(Path.join(out_dir, file)) == "old-#{file}"
      end

      assert File.read!(Path.join(out_dir, "encoder-manifest.json")) == old_manifest
      assert staging_directories(out_dir) == []
      refute File.exists?(lock_path(out_dir))
    end
  end

  test "downloader failure commits nothing and cleans staging", %{tmp_dir: tmp_dir} do
    out_dir = Path.join(tmp_dir, "encoder")
    counter = :counters.new(1, [])

    downloader = fn url, temporary ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1 do
        File.write(temporary, fixture_content(url))
      else
        {:error, :offline}
      end
    end

    opts =
      DownloadEncoder.options!(["--out", out_dir])
      |> Keyword.put(:downloader, downloader)

    assert {:error, {:download_failed, _url, :offline}} = DownloadEncoder.download(opts)

    for file <- Map.keys(@fixtures) ++ ["encoder-manifest.json"] do
      refute File.exists?(Path.join(out_dir, file))
    end

    assert staging_directories(out_dir) == []
    refute File.exists?(lock_path(out_dir))
  end

  test "an output lock prevents concurrent generations from interleaving", %{tmp_dir: tmp_dir} do
    out_dir = Path.join(tmp_dir, "concurrent-encoder")
    test_pid = self()
    counter = :counters.new(1, [])

    first_downloader = fn url, temporary ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1 do
        send(test_pid, {:first_download_locked, self()})

        receive do
          :continue_download -> File.write(temporary, fixture_content(url))
        after
          2_000 -> {:error, :coordination_timeout}
        end
      else
        File.write(temporary, fixture_content(url))
      end
    end

    first_opts =
      DownloadEncoder.options!(["--out", out_dir])
      |> Keyword.put(:downloader, first_downloader)

    first_task = Task.async(fn -> DownloadEncoder.download(first_opts) end)
    assert_receive {:first_download_locked, first_pid}, 1_000

    second_opts =
      DownloadEncoder.options!(["--out", out_dir])
      |> Keyword.put(:downloader, fn _url, _temporary ->
        send(test_pid, :second_downloader_invoked)
        :ok
      end)

    assert {:error, {:download_locked, lock_dir}} = DownloadEncoder.download(second_opts)
    assert lock_dir == lock_path(out_dir)
    refute_received :second_downloader_invoked

    send(first_pid, :continue_download)
    assert {:ok, _result} = Task.await(first_task, 5_000)
    refute File.exists?(lock_path(out_dir))
  end

  test "rejects a mismatched model before downloading", %{tmp_dir: tmp_dir} do
    out_dir = Path.join(tmp_dir, "encoder")
    checksum_manifest = Path.join(tmp_dir, "wrong-model.json")

    manifest =
      trusted_manifest(Map.new(@fixtures, fn {file, content} -> {file, sha256(content)} end))
      |> Map.put("model", "acme/other-model")

    File.write!(checksum_manifest, Jason.encode!(manifest))
    test_pid = self()

    opts =
      DownloadEncoder.options!([
        "--out",
        out_dir,
        "--checksum-manifest",
        checksum_manifest
      ])
      |> Keyword.put(:downloader, fn _url, _temporary ->
        send(test_pid, :downloader_invoked)
        :ok
      end)

    assert {:error,
            {:checksum_manifest_invalid, ^checksum_manifest,
             {:model_mismatch, @default_model, "acme/other-model"}}} =
             DownloadEncoder.download(opts)

    refute_received :downloader_invoked
    assert File.ls!(out_dir) == []
  end

  defp fixture_name(url) do
    cond do
      String.ends_with?(url, "/onnx/model.onnx") -> "model.onnx"
      String.ends_with?(url, "/tokenizer.json") -> "tokenizer.json"
      String.ends_with?(url, "/config.json") -> "config.json"
      true -> flunk("unexpected fixture URL: #{url}")
    end
  end

  defp fixture_content(url), do: Map.fetch!(@fixtures, fixture_name(url))

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp trusted_manifest(files) do
    %{
      "schema_version" => 1,
      "model" => @default_model,
      "revision" => @default_revision,
      "files" => files
    }
  end

  defp staging_directories(out_dir) do
    out_dir
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, ".spectre-download-"))
  end

  defp lock_path(out_dir), do: Path.join(out_dir, ".spectre-download.lock")
end
