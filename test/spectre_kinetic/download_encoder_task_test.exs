defmodule SpectreKinetic.DownloadEncoderTaskTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Spectre.DownloadEncoder

  @default_model "BAAI/bge-small-en-v1.5"
  @default_revision "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
  @custom_revision "0123456789abcdef0123456789abcdef01234567"

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
  end
end
